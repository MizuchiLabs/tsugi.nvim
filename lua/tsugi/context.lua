-- Cross-file context strategies. Each returns chunks ordered least relevant first,
-- so the most useful code sits right before the current file in the prompt.
local M = {}

M.budget = 6000

local recent = {}
local last_row = {}

---@param buf integer
---@param row integer
function M.touch(buf, row)
  for i, b in ipairs(recent) do
    if b == buf then
      table.remove(recent, i)
      break
    end
  end
  recent[#recent + 1] = buf
  last_row[buf] = row
  if #recent > 64 then
    table.remove(recent, 1)
  end
end

function M.reset()
  recent, last_row = {}, {}
end

local function eligible(buf, current)
  return buf ~= current
    and vim.api.nvim_buf_is_loaded(buf)
    and vim.bo[buf].buftype == ""
    and vim.api.nvim_buf_get_name(buf) ~= ""
end

local function path(buf)
  return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":.")
end

local function slice(buf, first, last)
  return table.concat(vim.api.nvim_buf_get_lines(buf, first - 1, last, false), "\n")
end

local stopwords = {}
for w in
  ([[
and break case catch chan class const continue def default defer else elif end enum err export
false for from func function if import in interface local map nil not null
package pass range return select self string struct switch then this true try type
var void while with async await let new int bool byte error any
]]):gmatch("%S+")
do
  stopwords[w] = true
end

local function idents(text, into)
  into = into or {}
  for w in text:gmatch("[%a_][%w_]*") do
    if #w >= 3 and not stopwords[w] then
      into[w] = (into[w] or 0) + 1
    end
  end
  return into
end

---@class tsugi.Query
---@field buf integer
---@field lines string[] the lines around the cursor
---@field row integer cursor row within lines

---@type table<string, fun(q: tsugi.Query, budget: integer): tsugi.Chunk[]>
local strategies = {}

function strategies.none()
  return {}
end

---Windows around where you last were in recently visited buffers.
function strategies.recent(q, budget)
  local out = {}
  for i = #recent, 1, -1 do
    local b = recent[i]
    if eligible(b, q.buf) then
      local row = last_row[b] or 1
      local text = slice(b, math.max(1, row - 30), row + 30)
      if #text > budget then
        break
      end
      budget = budget - #text
      table.insert(out, 1, { path = path(b), text = text })
      if #out >= 3 then
        break
      end
    end
  end
  return out
end

local chunk_cache = {}

local function chunks_of(buf)
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local c = chunk_cache[buf]
  if c and c.tick == tick then
    return c.chunks
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local chunks = {}
  for first = 1, math.max(1, #lines - 20), 20 do
    local last = math.min(#lines, first + 39)
    local text = table.concat(lines, "\n", first, last)
    local set, n = {}, 0
    for w in pairs(idents(text)) do
      set[w] = true
      n = n + 1
    end
    chunks[#chunks + 1] = { first = first, last = last, text = text, set = set, n = n }
  end
  chunk_cache[buf] = { tick = tick, chunks = chunks }
  return chunks
end

---Chunks from all loaded buffers ranked by identifier overlap with the code
---around the cursor (Jaccard), the "neighboring tabs" approach.
function strategies.similar(q, budget)
  local query, qn = {}, 0
  local text = table.concat(q.lines, "\n", math.max(1, q.row - 30), math.min(#q.lines, q.row + 10))
  for w in pairs(idents(text)) do
    query[w] = true
    qn = qn + 1
  end
  if qn == 0 then
    return {}
  end

  local scored = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if eligible(b, q.buf) then
      for _, c in ipairs(chunks_of(b)) do
        local common = 0
        for w in pairs(c.set) do
          if query[w] then
            common = common + 1
          end
        end
        local score = common / (qn + c.n - common)
        if score > 0.08 then
          scored[#scored + 1] = { buf = b, chunk = c, score = score }
        end
      end
    end
  end
  table.sort(scored, function(a, b)
    return a.score > b.score
  end)

  local out, taken = {}, {}
  for _, s in ipairs(scored) do
    local overlap = false
    for _, t in ipairs(taken) do
      if t.buf == s.buf and s.chunk.first <= t.chunk.last and t.chunk.first <= s.chunk.last then
        overlap = true
        break
      end
    end
    if not overlap and #s.chunk.text <= budget then
      budget = budget - #s.chunk.text
      taken[#taken + 1] = s
      table.insert(out, 1, { path = path(s.buf), text = s.chunk.text })
      if #out >= 4 then
        break
      end
    end
  end
  return out
end

local def_patterns = {
  "^func%s+%b()%s*([%w_]+)",
  "^func%s+([%w_]+)",
  "^type%s+([%w_]+)",
  "^%s*local%s+function%s+([%w_]+)",
  "^%s*function%s+[%w_]+[.:]([%w_]+)",
  "^%s*function%s+([%w_]+)",
  "^%s*[%w_]+%.([%w_]+)%s*=%s*function",
  "^%s*export%s+default%s+function%s+([%w_]+)",
  "^%s*export%s+async%s+function%s+([%w_]+)",
  "^%s*export%s+function%s+([%w_]+)",
  "^%s*async%s+function%s+([%w_]+)",
  "^%s*export%s+const%s+([%w_]+)",
  "^%s*export%s+class%s+([%w_]+)",
  "^%s*export%s+interface%s+([%w_]+)",
  "^%s*export%s+type%s+([%w_]+)",
  "^%s*interface%s+([%w_]+)",
  "^%s*class%s+([%w_]+)",
  "^%s*def%s+([%w_]+)",
}

local def_cache = {}

local function defs_of(buf)
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local c = def_cache[buf]
  if c and c.tick == tick then
    return c.defs
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local defs = {}
  for i, l in ipairs(lines) do
    for _, p in ipairs(def_patterns) do
      local name = l:match(p)
      if name then
        defs[name] = defs[name] or {}
        table.insert(defs[name], i)
        break
      end
    end
  end
  def_cache[buf] = { tick = tick, defs = defs, lines = lines }
  return defs
end

local function def_snippet(lines, at)
  local indent = lines[at]:match("^%s*")
  local opens = lines[at]:match("[{(%[]%s*$") or lines[at]:match("function") or lines[at]:match(":%s*$")
  local last = at
  for i = at + 1, math.min(#lines, at + 24) do
    local l = lines[i]
    if not opens and l:match("^%s*$") then
      break
    end
    last = i
    if opens and l:match("^" .. indent .. "[})%]]") or (opens and l:match("^" .. indent .. "end")) then
      break
    end
  end
  return table.concat(lines, "\n", at, last)
end

---Definitions (funcs, types, classes) from other buffers for identifiers used
---near the cursor. A poor man's go-to-definition, no LSP needed.
function strategies.defs(q, budget)
  local wanted = idents(table.concat(q.lines, "\n", math.max(1, q.row - 20), math.min(#q.lines, q.row + 5)))
  local names = {}
  for w, n in pairs(wanted) do
    names[#names + 1] = { name = w, n = n }
  end
  table.sort(names, function(a, b)
    return a.n > b.n or (a.n == b.n and a.name < b.name)
  end)

  local bufs = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if eligible(b, q.buf) then
      defs_of(b)
      bufs[#bufs + 1] = b
    end
  end

  local out = {}
  for _, entry in ipairs(names) do
    local found = 0
    for _, b in ipairs(bufs) do
      local c = def_cache[b]
      for _, at in ipairs(c.defs[entry.name] or {}) do
        local text = def_snippet(c.lines, at)
        if #text <= budget then
          budget = budget - #text
          table.insert(out, 1, { path = path(b), text = text })
          found = found + 1
        end
        if found >= 2 then
          break
        end
      end
      if found >= 2 then
        break
      end
    end
    if #out >= 8 or budget < 200 then
      break
    end
  end
  return out
end

M.strategies = strategies

---@param names string[]
---@param q tsugi.Query
---@return tsugi.Chunk[]
function M.collect(names, q)
  local out = {}
  local share = math.floor(M.budget / math.max(1, #names))
  for i = #names, 1, -1 do
    local s = strategies[names[i]]
    if s then
      for _, c in ipairs(s(q, share)) do
        table.insert(out, 1, c)
      end
    end
  end
  return out
end

---Line range around row with edges snapped to a grid, so the prompt stays
---byte-identical (and cached by llama.cpp) while the cursor moves.
---@return integer first, integer last
function M.window(row, nlines, above, below)
  local grid = 32
  local first = math.max(1, math.floor((row - above) / grid) * grid + 1)
  local last = math.min(nlines, math.ceil((row + below) / grid) * grid)
  return first, last
end

return M

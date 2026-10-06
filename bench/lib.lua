local M = {}

M.root = vim.fs.dirname(vim.fs.dirname(vim.fs.abspath(arg[0])))
M.url = os.getenv "TSUGI_URL" or "http://127.0.0.1:8080"

---Parses `--key value` pairs over the given defaults.
function M.args(defaults)
  local opts = vim.deepcopy(defaults)
  for i = 1, #arg, 2 do
    opts[arg[i]:gsub("^%-%-", "")] = arg[i + 1]
  end
  return opts
end

function M.list(s)
  return s and vim.split(s, ",", { trimempty = true }) or nil
end

function M.percentile(xs, p)
  if #xs == 0 then
    return 0
  end
  local sorted = vim.list_slice(xs)
  table.sort(sorted)
  return sorted[math.max(1, math.ceil(#sorted * p))]
end

local starts = {
  "^func ",
  "^%s*local%s+function%s",
  "^%s*function%s",
  "^%s*[%w_.]+%s*=%s*function",
  "^%s*export%s+async%s+function%s",
  "^%s*export%s+function%s",
  "^%s*async%s+function%s",
  "^%s*const%s+[%w_]+%s*=%s*.*=>%s*{%s*$",
}

local function is_start(line)
  for _, p in ipairs(starts) do
    if line:match(p) then
      return true
    end
  end
  return false
end

---Functions of 6 to 40 lines: signature at `first`, closing line at `last`.
local function find_funcs(file, lines)
  local out = {}
  for i, l in ipairs(lines) do
    if is_start(l) and (l:match "[{(]%s*$" or l:match "function.*%)%s*$") then
      local indent = l:match "^%s*"
      for j = i + 1, math.min(#lines, i + 60) do
        local e = lines[j]
        if e:match("^" .. indent .. "[})]") or e:match("^" .. indent .. "end") then
          if j - i >= 6 and j - i <= 40 then
            out[#out + 1] = { file = file, first = i, last = j }
          end
          break
        end
        if indent == "" and e:match "^%S" and not e:match "^[})]" then
          break
        end
      end
    end
  end
  return out
end

local function indent(s)
  return #s:match "^%s*"
end

---Indented blocks of 5 to 30 lines, for markup and config: the opening line at
---`first`, the first line back at its indent (closer or next sibling) at `last`.
local function find_blocks(file, lines)
  local out = {}
  for i, l in ipairs(lines) do
    local nxt = lines[i + 1]
    if l:match "%S" and nxt and nxt:match "%S" and indent(nxt) > indent(l) then
      for j = i + 1, math.min(#lines, i + 40) do
        if lines[j]:match "%S" and indent(lines[j]) <= indent(l) then
          if j - i >= 5 and j - i <= 30 then
            out[#out + 1] = { file = file, first = i, last = j }
          end
          break
        end
      end
    end
  end
  return out
end

local function files_of(suite, repo)
  local files = {}
  local git = vim.system({ "git", "-C", repo, "ls-files", unpack(suite.glob) }, { text = true }):wait()
  if git.code == 0 then
    files = vim.split(git.stdout, "\n", { trimempty = true })
  else
    for _, g in ipairs(suite.glob) do
      for _, f in ipairs(vim.fn.globpath(repo, "**/" .. g, false, true)) do
        files[#files + 1] = f:sub(#repo + 2)
      end
    end
  end
  return vim.tbl_filter(function(f)
    for _, ex in ipairs(suite.exclude or {}) do
      if f:find(ex, 1, true) then
        return false
      end
    end
    return true
  end, files)
end

---Fetches a pinned public repo into bench/cache on first use.
---@return string dir
---@return fun(...: string): string git runs git in dir and returns its output
local function fetch(suite)
  local dir = M.root .. "/bench/cache/" .. suite.name
  local function git(...)
    local r = vim.system({ "git", "-C", dir, ... }, { text = true }):wait()
    assert(r.code == 0, r.stderr)
    return r.stdout
  end
  if not vim.uv.fs_stat(dir) then
    vim.fn.mkdir(dir, "p")
    git("init", "-q")
    git("fetch", "-q", "--depth", "1", suite.url, suite.rev, suite.base)
    git("checkout", "-q", suite.rev)
  end
  return dir, git
end

local function shuffle(t)
  for i = #t, 2, -1 do
    local j = math.random(i)
    t[i], t[j] = t[j], t[i]
  end
end

---@param filter? string[] suite names
function M.suites(filter)
  return vim.tbl_filter(function(s)
    return not filter or vim.tbl_contains(filter, s.name)
  end, dofile(M.root .. "/bench/suites.lua"))
end

---Deterministic per suite: files in a random visiting order and the picked
---functions, at most one per file.
function M.load(suite, seed)
  math.randomseed(seed)
  local repo, added
  if suite.url then
    local git
    repo, git = fetch(suite)
    if suite.base then
      added = {}
      for f in git("diff", "-M", "-l0", "--diff-filter=A", "--name-only", suite.base, suite.rev):gmatch "[^\n]+" do
        added[f] = true
      end
    end
  else
    repo = vim.fs.normalize(suite.repo)
  end
  local files = files_of(suite, repo)
  local contents, funcs = {}, {}
  for _, f in ipairs(files) do
    contents[f] = vim.fn.readfile(repo .. "/" .. f)
    if (not suite.pick or f:match(suite.pick)) and (not added or added[f]) then
      vim.list_extend(funcs, (suite.blocks and find_blocks or find_funcs)(f, contents[f]))
    end
  end
  shuffle(files)
  shuffle(funcs)
  local picked, seen = {}, {}
  for _, fn in ipairs(funcs) do
    if #picked < suite.funcs and not seen[fn.file] then
      seen[fn.file] = true
      picked[#picked + 1] = fn
    end
  end
  if suite.files then
    local some = {}
    for _, f in ipairs(files) do
      if seen[f] or #some < suite.files then
        some[#some + 1] = f
      end
    end
    files = some
  end
  return { repo = repo, files = files, contents = contents, picked = picked }
end

return M

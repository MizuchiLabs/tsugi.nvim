---@class tsugi.Edit
---@field path string
---@field start integer 1-based first line of the edited range
---@field old string
---@field new string

---@class tsugi.Chunk
---@field path string
---@field text string

---@class tsugi.Context
---@field path string
---@field lines string[]
---@field row integer 1-based
---@field col integer 0-based byte offset
---@field chunks? tsugi.Chunk[] cross-file context, most relevant last
---@field history? tsugi.Edit[] oldest first

---@class tsugi.Request
---@field prompt string
---@field stop string[]
---@field n_predict integer
---@field first? integer rewrite: first buffer line the output replaces
---@field last? integer rewrite: last buffer line the output replaces
---@field prefill? string rewrite: output prefix sent as part of the prompt
---@field strip? string rewrite: marker to strip from the start of the output

local M = { fim = {}, nes = {} }

local function join(lines, first, last)
  return table.concat(lines, "\n", math.max(first, 1), math.min(last, #lines))
end

---Everything above the cursor in ctx.lines is prefix. Callers window the lines.
local function split_at_cursor(ctx, after)
  local line = ctx.lines[ctx.row]
  local prefix = ""
  if ctx.row > 1 then
    prefix = join(ctx.lines, 1, ctx.row - 1) .. "\n"
  end
  prefix = prefix .. line:sub(1, ctx.col)
  local suffix = line:sub(ctx.col + 1)
  if ctx.row < #ctx.lines then
    suffix = suffix .. "\n" .. join(ctx.lines, ctx.row + 1, ctx.row + after)
  end
  return prefix, suffix
end

local function chunk_blocks(chunks, header)
  local out = {}
  for _, c in ipairs(chunks or {}) do
    out[#out + 1] = header .. c.path .. "\n" .. c.text .. "\n"
  end
  return table.concat(out)
end

-- Suffix-first layouts keep the prompt cacheable while typing: only the tail changes.

---Mellum: SPM with <filename> headers.
---@param ctx tsugi.Context
---@return tsugi.Request
function M.fim.mellum(ctx)
  local prefix, suffix = split_at_cursor(ctx, 64)
  return {
    prompt = chunk_blocks(ctx.chunks, "<filename>")
      .. "<filename>"
      .. ctx.path
      .. "\n<fim_suffix>"
      .. suffix
      .. "<fim_prefix>"
      .. prefix
      .. "<fim_middle>",
    stop = { "<fim_prefix>", "<fim_suffix>", "<fim_middle>", "<filename>" },
    n_predict = 128,
  }
end

---Qwen2.5-Coder PSM with repo-level file separators. sweep-next-edit inherits it.
---@param ctx tsugi.Context
---@return tsugi.Request
function M.fim.qwen(ctx)
  local prefix, suffix = split_at_cursor(ctx, 20)
  return {
    prompt = chunk_blocks(ctx.chunks, "<|file_sep|>")
      .. "<|file_sep|>"
      .. ctx.path
      .. "\n<|fim_prefix|>"
      .. prefix
      .. "<|fim_suffix|>"
      .. suffix
      .. "<|fim_middle|>",
    stop = { "<|file_sep|>", "<|fim_prefix|>", "<|fim_suffix|>", "<|fim_middle|>", "<|endoftext|>" },
    n_predict = 128,
  }
end

---sweep-next-edit-v2, following sweepai's reference inference.py.
---@param ctx tsugi.Context
---@return tsugi.Request
function M.nes.sweep(ctx)
  local first = math.max(1, ctx.row - 10)
  local last = math.min(#ctx.lines, ctx.row + 10)
  local block = join(ctx.lines, first, last)

  local line = ctx.lines[ctx.row]
  local marked = {}
  for i = first, last do
    marked[#marked + 1] = i == ctx.row and (line:sub(1, ctx.col) .. "<|cursor|>" .. line:sub(ctx.col + 1))
      or ctx.lines[i]
  end

  local prefill = ctx.row > first and (join(ctx.lines, first, ctx.row - 1) .. "\n") or ""

  local changes = {}
  for _, e in ipairs(ctx.history or {}) do
    local n = select(2, e.new:gsub("\n", "")) + 1
    changes[#changes + 1] = ("<|file_sep|>%s:%d:%d\noriginal:\n%s\nupdated:\n%s"):format(
      e.path,
      e.start,
      e.start + n - 1,
      e.old,
      e.new
    )
  end

  local range = ("%s:%d:%d"):format(ctx.path, first, last)
  local prompt = table.concat({
    "<|file_sep|>" .. ctx.path,
    join(ctx.lines, ctx.row - 150, ctx.row + 150) .. chunk_blocks(ctx.chunks, "\n<|file_sep|>"),
    table.concat(changes, "\n"),
    "<|file_sep|>original/" .. range,
    block,
    "<|file_sep|>current/" .. range,
    table.concat(marked, "\n"),
    "<|file_sep|>updated/" .. range,
    prefill,
  }, "\n")

  return {
    prompt = prompt,
    stop = { "<|file_sep|>", "<|endoftext|>" },
    n_predict = 512,
    first = first,
    last = last,
    prefill = prefill,
  }
end

---zeta-2.1: SeedCoder SPM envelope with one marker-bounded editable region.
---@param ctx tsugi.Context
---@return tsugi.Request
function M.nes.zeta(ctx)
  local first = math.max(1, ctx.row - 4)
  local last = math.min(#ctx.lines, ctx.row + 8)

  local line = ctx.lines[ctx.row]
  local editable = {}
  for i = first, last do
    editable[#editable + 1] = i == ctx.row and (line:sub(1, ctx.col) .. "<|user_cursor|>" .. line:sub(ctx.col + 1))
      or ctx.lines[i]
  end

  local history = {}
  for _, e in ipairs(ctx.history or {}) do
    local hunk = { "--- a/" .. e.path, "+++ b/" .. e.path }
    local old, new = vim.split(e.old, "\n"), vim.split(e.new, "\n")
    hunk[#hunk + 1] = ("@@ -%d,%d +%d,%d @@"):format(e.start, #old, e.start, #new)
    for _, l in ipairs(old) do
      hunk[#hunk + 1] = "-" .. l
    end
    for _, l in ipairs(new) do
      hunk[#hunk + 1] = "+" .. l
    end
    history[#history + 1] = table.concat(hunk, "\n")
  end

  local parts = { "<[fim-suffix]>" }
  if last < #ctx.lines then
    parts[#parts + 1] = join(ctx.lines, last + 1, last + 60) .. "\n"
  end
  parts[#parts + 1] = "<[fim-prefix]>"
  parts[#parts + 1] = chunk_blocks(ctx.chunks, "<filename>")
  if #history > 0 then
    parts[#parts + 1] = "<filename>edit_history\n" .. table.concat(history, "\n") .. "\n\n"
  end
  parts[#parts + 1] = "<filename>" .. ctx.path .. "\n"
  if first > 1 then
    parts[#parts + 1] = join(ctx.lines, first - 120, first - 1) .. "\n"
  end
  parts[#parts + 1] = "<|marker_1|>\n" .. table.concat(editable, "\n") .. "\n<|marker_2|>\n<[fim-middle]>"

  return {
    prompt = table.concat(parts),
    stop = { "<[end▁of▁sentence]>" },
    n_predict = 512,
    first = first,
    last = last,
    prefill = "",
    strip = "<|marker_1|>\n",
  }
end

return M

-- Quality replay: retypes real functions top-down and asks for a completion at
-- sampled cursor points, with every repo file open as a buffer.
--
-- shown: points with a suggestion. ok: shown ones that are a prefix of what was
-- really typed. line: shown ones whose first line matches exactly. wrong: shown
-- ones that diverge. sv/pt: chars a user would accept per point (full accept
-- when ok, word-wise up to the first mistake otherwise).
--
-- nvim -l bench/replay.lua [--suite go,lua] [--model mellum,sweep]
--   [--context none,defs,similar,recent,defs+recent] [--points 8] [--seed 1] [--lines block|N] [--suffix N]
local lib = dofile(vim.fs.dirname(vim.fs.abspath(arg[0])) .. "/lib.lua")
vim.opt.rtp:prepend(lib.root)

local complete = require "tsugi.complete"
local config = require "tsugi.config"
local context = require "tsugi.context"
local format = require "tsugi.format"

local opts = lib.args {
  model = "mellum,sweep",
  context = "none,defs,similar,recent",
  points = "8",
  seed = "1",
  lines = "block",
  suffix = "",
}
local limit = tonumber(opts.lines) or opts.lines
if opts.suffix ~= "" then
  for name in pairs(format.suffix) do
    format.suffix[name] = tonumber(opts.suffix)
  end
end

---Points spread over the function body: line starts and a mid-line spot.
local function points_of(lines, fn, max)
  local all = {}
  for r = fn.first + 1, fn.last - 1 do
    local l = lines[r]
    local indent = #l:match "^%s*"
    if #l - indent >= 4 then
      all[#all + 1] = { row = r, col = indent }
      local mid = l:find("[%s(.=:,]", indent + math.floor((#l - indent) / 3))
      if mid and mid < #l - 2 then
        all[#all + 1] = { row = r, col = mid }
      end
    end
  end
  if #all <= max then
    return all
  end
  local out = {}
  for i = 1, max do
    out[i] = all[math.floor((i - 1) * #all / max) + 1]
  end
  return out
end

local function word_snap(s, n)
  while n > 0 and s:sub(n + 1, n + 1):match "[%w_]" and s:sub(n, n):match "[%w_]" do
    n = n - 1
  end
  return n
end

local function score(truth, got)
  if got == "" then
    return { kind = "empty", saved = 0 }
  end
  local tfirst = truth:match("^[^\n]*"):gsub("%s+$", "")
  local gfirst = got:match("^[^\n]*"):gsub("%s+$", "")
  local line_ok = tfirst == gfirst
  if vim.startswith(truth, got) then
    return { kind = "ok", saved = #got, line_ok = line_ok }
  end
  local n = 0
  while n < #got and got:byte(n + 1) == truth:byte(n + 1) do
    n = n + 1
  end
  return { kind = "wrong", saved = word_snap(got, n), line_ok = line_ok }
end

local function run_point(model, names, buf, path, lines, pt)
  local first, last = context.window(pt.row, #lines, 120, 40)
  local ctx = {
    path = path,
    lines = vim.list_slice(lines, first, last),
    row = pt.row - first + 1,
    col = pt.col,
  }
  local t = vim.uv.hrtime()
  ctx.chunks = context.collect(names, { buf = buf, lines = ctx.lines, row = ctx.row })
  local ctx_ms = (vim.uv.hrtime() - t) / 1e6

  local result
  local t0 = vim.uv.hrtime()
  complete.fim(lib.url, model, ctx, limit, function(text, done, info)
    if done then
      result = { text = text, info = info, ms = (vim.uv.hrtime() - t0) / 1e6 }
    end
  end)
  vim.wait(30000, function()
    return result ~= nil
  end, 2)
  result = result or { text = "", info = { error = "timeout" }, ms = 30000 }
  result.ctx_ms = ctx_ms
  return result
end

local out_dir = lib.root .. "/bench/out"
vim.fn.mkdir(out_dir, "p")

io.write(
  ("%-7s %-7s %-12s %4s %6s %6s %6s %6s %6s %6s %6s %6s %6s\n"):format(
    "suite",
    "model",
    "context",
    "n",
    "shown",
    "ok",
    "line",
    "wrong",
    "sv/pt",
    "p50",
    "p90",
    "ctxms",
    "kchar"
  )
)

for _, suite in ipairs(lib.suites(lib.list(opts.suite))) do
  local set = lib.load(suite, tonumber(opts.seed))
  local contents, picked = set.contents, set.picked
  vim.fn.chdir(set.repo)
  context.reset()

  local bufs = {}
  for _, f in ipairs(set.files) do
    local b = vim.fn.bufadd(f)
    vim.fn.bufload(b)
    vim.bo[b].buflisted = true
    bufs[f] = b
    context.touch(b, math.random(math.max(1, #contents[f])))
  end

  for _, model_name in ipairs(lib.list(opts.model)) do
    local model = config.models[model_name]
    for _, ctx_name in ipairs(lib.list(opts.context)) do
      local names = vim.split(ctx_name, "+", { plain = true })
      local stats = { n = 0, shown = 0, ok = 0, line = 0, wrong = 0, saved = 0, ms = {}, ctx_ms = 0, chars = 0 }
      local log =
        assert(io.open(("%s/%s-%s-%s-%s.jsonl"):format(out_dir, suite.name, model_name, ctx_name, opts.lines), "w"))

      for _, fn in ipairs(picked) do
        local lines = contents[fn.file]
        local buf = bufs[fn.file]
        vim.api.nvim_set_current_buf(buf)
        for _, pt in ipairs(points_of(lines, fn, tonumber(opts.points))) do
          local virtual = vim.list_slice(lines, 1, pt.row - 1)
          virtual[#virtual + 1] = lines[pt.row]:sub(1, pt.col)
          vim.list_extend(virtual, lines, fn.last)
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, virtual)

          local truth = lines[pt.row]:sub(pt.col + 1)
          if fn.last - 1 > pt.row then
            truth = truth .. "\n" .. table.concat(lines, "\n", pt.row + 1, fn.last - 1)
          end

          local r = run_point(model, names, buf, fn.file, virtual, pt)
          local s = score(truth, r.text)
          stats.n = stats.n + 1
          stats.ms[#stats.ms + 1] = r.ms
          stats.ctx_ms = stats.ctx_ms + r.ctx_ms
          stats.chars = stats.chars + r.info.prompt_chars
          if s.kind ~= "empty" then
            stats.shown = stats.shown + 1
            stats.saved = stats.saved + s.saved
            stats[s.kind] = stats[s.kind] + 1
            if s.line_ok then
              stats.line = stats.line + 1
            end
          end
          log:write(
            vim.json.encode {
              file = fn.file,
              row = pt.row,
              col = pt.col,
              kind = s.kind,
              saved = s.saved,
              ms = math.floor(r.ms),
              conf = r.info.confidence,
              got = r.text,
              want = truth:sub(1, 300),
              error = r.info.error,
            },
            "\n"
          )
        end
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      end
      log:close()

      local pct = function(x, of)
        return of > 0 and ("%5.0f%%"):format(100 * x / of) or "     -"
      end
      io.write(
        ("%-7s %-7s %-12s %4d %s %s %s %s %s %6.0f %6.0f %6.1f %6.1f\n"):format(
          suite.name,
          model_name,
          ctx_name,
          stats.n,
          pct(stats.shown, stats.n),
          pct(stats.ok, stats.shown),
          pct(stats.line, stats.shown),
          pct(stats.wrong, stats.shown),
          ("%6.1f"):format(stats.saved / math.max(1, stats.n)),
          lib.percentile(stats.ms, 0.5),
          lib.percentile(stats.ms, 0.9),
          stats.ctx_ms / math.max(1, stats.n),
          stats.chars / math.max(1, stats.n) / 1000
        )
      )
      io.flush()
    end
  end
end

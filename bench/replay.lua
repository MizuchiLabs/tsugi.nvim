-- Quality replay: retypes real functions top-down and asks for a completion at
-- sampled cursor points, with every repo file open as a buffer.
--
-- shown: points with a suggestion. ok: shown ones that are a prefix of what was
-- really typed. line: shown ones whose first line matches exactly. wrong: shown
-- ones that diverge. sv/pt: chars a user would accept per point (full accept
-- when ok, word-wise up to the first mistake otherwise).
--
-- With --pairs true the cursor sits right after an opening bracket or quote and
-- the closer is already in the buffer, the state an autopairs plugin leaves.
-- The truth is then the text up to that closer.
--
-- The log keeps every token's length and logprob. Run with --confidence off to
-- log the uncut text, then other floors can be tried on the log without a rerun.
--
-- nvim -l bench/replay.lua [--suite go,lua] [--model mellum,sweep]
--   [--context none,defs,similar,recent,defs+recent] [--points 8] [--seed 1] [--lines block|N] [--suffix N]
--   [--confidence 0.7|off] [--pairs true]
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
  confidence = tostring(config.confidence),
  pairs = "false",
}
local limits = { lines = tonumber(opts.lines) or opts.lines, confidence = tonumber(opts.confidence) or false }
if opts.suffix ~= "" then
  for name in pairs(format.suffix) do
    format.suffix[name] = tonumber(opts.suffix)
  end
end

---At most max of the points, evenly spread.
local function spread(all, max)
  if #all <= max then
    return all
  end
  local out = {}
  for i = 1, max do
    out[i] = all[math.floor((i - 1) * #all / max) + 1]
  end
  return out
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
  return spread(all, max)
end

local closers = { ["("] = ")", ["["] = "]", ["{"] = "}", ["\""] = "\"" }

---The closer matching the opener at s, when it is on the same line.
local function closer_of(l, s)
  local open = l:sub(s, s)
  local close = closers[open]
  if open == close then
    return l:find(close, s + 1, true)
  end
  local depth = 0
  for i = s, #l do
    local c = l:sub(i, i)
    if c == open then
      depth = depth + 1
    elseif c == close and depth == 1 then
      return i
    elseif c == close then
      depth = depth - 1
    end
  end
end

---One point per line: just inside the first opener that closes on that line.
local function pair_points_of(lines, fn, max)
  local all = {}
  for r = fn.first + 1, fn.last - 1 do
    local l = lines[r]
    for s = 1, #l do
      local e = closers[l:sub(s, s)] and closer_of(l, s)
      if e and e - s > 2 then
        all[#all + 1] = { row = r, col = s, close = l:sub(e, e), inside = l:sub(s + 1, e - 1) }
        break
      end
    end
  end
  return spread(all, max)
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
  local first, last = context.window(pt.row, #lines, 120, format.suffix[model.fim])
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
  complete.fim(lib.url, model, ctx, limits, function(text, done, info)
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
      local pairs_mode = opts.pairs == "true"
      local log = assert(
        io.open(
          ("%s/%s-%s-%s-%s%s.jsonl"):format(
            out_dir,
            suite.name,
            model_name,
            ctx_name,
            opts.lines,
            pairs_mode and "-pairs" or ""
          ),
          "w"
        )
      )

      for _, fn in ipairs(picked) do
        local lines = contents[fn.file]
        local buf = bufs[fn.file]
        vim.api.nvim_set_current_buf(buf)
        for _, pt in ipairs((pairs_mode and pair_points_of or points_of)(lines, fn, tonumber(opts.points))) do
          local virtual = vim.list_slice(lines, 1, pt.row - 1)
          virtual[#virtual + 1] = lines[pt.row]:sub(1, pt.col) .. (pt.close or "")
          vim.list_extend(virtual, lines, fn.last)
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, virtual)

          local truth = pt.inside or lines[pt.row]:sub(pt.col + 1)
          if not pt.inside and fn.last - 1 > pt.row then
            truth = truth .. "\n" .. table.concat(lines, "\n", pt.row + 1, fn.last - 1)
          end

          local r = run_point(model, names, buf, fn.file, virtual, pt)
          local s = score(truth, r.text)
          local tokens = {}
          for i, t in ipairs(r.info.tokens or {}) do
            tokens[i] = { t.len, t.logprob }
          end
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
              cut = r.info.cut,
              tokens = tokens,
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

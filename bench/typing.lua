-- Real-time typing sim: drives an embedded nvim running tsugi, retyping real
-- functions at a given speed. A simulated user accepts once a ghost has been
-- visible for `reaction` ms: all of it when right, else the first line or the
-- next word when those are right. Chained accepts take half the reaction time.
--
-- nvim -l bench/typing.lua [--suite go] [--funcs 3] [--model sweep]
--   [--context defs] [--wpm 100] [--reaction 250] [--seed 1] [--debounce 20] [--lines block|N] [--confidence -0.1|off]
local lib = dofile(vim.fs.dirname(vim.fs.abspath(arg[0])) .. "/lib.lua")

local opts = lib.args({
  suite = "go",
  funcs = "3",
  model = "sweep",
  context = "defs",
  wpm = "100",
  reaction = "250",
  seed = "1",
  debounce = "20",
  prefetch = "true",
  lines = "block",
  confidence = "-0.1",
  verbose = "false",
})

local function now()
  return vim.uv.hrtime() / 1e6
end

local child_init = [[
local root, url, model, names, debounce, prefetch, lines, confidence = ...
vim.opt.rtp:prepend(root)
vim.cmd("filetype off")
vim.o.autoindent = false
vim.o.smartindent = false
vim.o.cindent = false
vim.o.indentexpr = ""
vim.o.swapfile = false
require("tsugi").setup({ url = url, model = model, context = names, debounce = debounce, prefetch = prefetch, lines = lines, confidence = confidence })
_G.log = {}
local function now()
  return vim.uv.hrtime() / 1e6
end
require("tsugi.engine").on_event = function(ev, data)
  table.insert(_G.log, { t = now(), ev = ev, purpose = data.purpose, ms = data.ms })
end
local ui = require("tsugi.ui")
local show, clear = ui.show, ui.clear
ui.show = function(buf, row, col, text)
  table.insert(_G.log, { t = now(), ev = "ui", text = text })
  return show(buf, row, col, text)
end
ui.clear = function(buf)
  table.insert(_G.log, { t = now(), ev = "ui", text = "" })
  return clear(buf)
end
]]

local suite = lib.suites({ opts.suite })[1]
local set = lib.load(suite, tonumber(opts.seed))
local chan = vim.fn.jobstart({ "nvim", "--embed", "--headless", "--clean", "-n" }, { rpc = true, cwd = set.repo })
local function lua(code, ...)
  return vim.rpcrequest(chan, "nvim_exec_lua", code, { ... })
end
local keys_at = {}
local function input(keys)
  keys_at[#keys_at + 1] = now()
  vim.rpcrequest(chan, "nvim_input", keys)
end

lua(
  child_init,
  lib.root,
  lib.url,
  opts.model,
  vim.split(opts.context, "+", { plain = true }),
  tonumber(opts.debounce),
  opts.prefetch == "true",
  tonumber(opts.lines) or opts.lines,
  tonumber(opts.confidence) or false
)
local visits = {}
for _, f in ipairs(set.files) do
  visits[#visits + 1] = { f, math.random(math.max(1, #set.contents[f])) }
end
lua(
  [[
  local context = require("tsugi.context")
  for _, v in ipairs(...) do
    local b = vim.fn.bufadd(v[1])
    vim.fn.bufload(b)
    vim.bo[b].buflisted = true
    context.touch(b, v[2])
  end
]],
  visits
)

local cps = tonumber(opts.wpm) * 5 / 60
local reaction = tonumber(opts.reaction)
local total = {
  chars = 0,
  typed = 0,
  accepted = 0,
  accepts = 0,
  all = 0,
  line = 0,
  word = 0,
  wrong_head = 0,
  obs = 0,
  good = 0,
  wrong = 0,
  hides = 0,
  flickers = 0,
  requests = 0,
  prefetches = 0,
  cancels = 0,
  hits = 0,
  adopts = 0,
  mismatch = 0,
  show_ms = {},
  secs = 0,
}

local function key_for(c)
  if c == "\n" then
    return "<CR>"
  elseif c == "\t" then
    return "<C-v><Tab>"
  elseif c == "<" then
    return "<lt>"
  end
  return c
end

for i = 1, math.min(tonumber(opts.funcs), #set.picked) do
  local fn = set.picked[i]
  local lines = set.contents[fn.file]
  local virtual = vim.list_slice(lines, 1, fn.first)
  vim.list_extend(virtual, lines, fn.last)
  lua(
    [[
    local file, virtual, row = ...
    vim.cmd("stopinsert")
    vim.cmd.buffer(vim.fn.bufnr(file))
    require("tsugi.engine").reset()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, virtual)
    vim.api.nvim_win_set_cursor(0, { row, 0 })
    _G.log = {}
  ]],
    fn.file,
    virtual,
    fn.first
  )
  input("A")
  keys_at = {}

  local truth = "\n" .. table.concat(lines, "\n", fn.first + 1, fn.last - 1)
  local pos, seen_at, last_wrong, chained = 1, nil, nil, false
  local t_start = now()
  local stats = { typed = 0, accepted = 0, accepts = 0 }

  while pos <= #truth do
    local vis = lua("return require('tsugi.engine').visible()")
    if vis == vim.NIL then
      vis = nil
    end
    local rest = truth:sub(pos)
    local good = vis and vim.startswith(rest, vis)
    local first = vis and vis:match("^[^\n]+")
    local word = vis and (vis:match("^%s*[%w_]+") or vis:match("^%s*[^%w_%s]+"))
    local action
    if good then
      action = { key = "<M-f>", take = vis, kind = "all" }
    elseif first and #vim.trim(first) >= 3 and vim.startswith(rest, first) then
      action = { key = "<C-l>", take = first, kind = "line" }
    elseif word and vim.startswith(rest, word) then
      action = { key = "<C-Right>", take = word, kind = "word" }
    end

    total.obs = total.obs + 1
    if good then
      total.good = total.good + 1
    elseif vis then
      total.wrong = total.wrong + 1
      if not action then
        total.wrong_head = total.wrong_head + 1
      end
      if opts.verbose == "true" and vis ~= last_wrong then
        io.write(("  wrong %q\n   want %q\n"):format(vis:sub(1, 80), rest:sub(1, 80)))
      end
      last_wrong = vis
    end

    seen_at = action and (seen_at or now()) or nil
    -- A user chaining accepts is quicker than one reacting to a fresh ghost.
    local wait = chained and reaction / 2 or reaction
    if action and now() - seen_at >= wait then
      input(action.key)
      if opts.verbose == "true" then
        io.write(("  accept %s %q\n"):format(action.kind, action.take))
      end
      pos = pos + #action.take
      stats.accepted = stats.accepted + #action.take
      stats.accepts = stats.accepts + 1
      total[action.kind] = total[action.kind] + 1
      seen_at, chained = nil, true
      vim.wait(15)
    else
      chained = false
      local c = truth:sub(pos, pos)
      input(key_for(c))
      pos = pos + 1
      stats.typed = stats.typed + 1
      local gap = 1000 / cps * (0.7 + math.random() * 0.6)
      if c == "\n" then
        gap = gap + 250
      end
      vim.wait(gap)
    end
  end
  vim.wait(50)

  local got = lua("vim.cmd('stopinsert') return vim.api.nvim_buf_get_lines(0, 0, -1, false)")
  local ok = table.concat(got, "\n") == table.concat(lines, "\n")
  if not ok then
    total.mismatch = total.mismatch + 1
    local diff = vim.text.diff(table.concat(lines, "\n") .. "\n", table.concat(got, "\n") .. "\n", { ctxlen = 1 })
    io.write(("MISMATCH %s:%d\n%s\n"):format(fn.file, fn.first, diff))
  end

  local log = lua("return _G.log")
  local shown, req_t, shown_at, k = false, {}, 0, 1
  for _, e in ipairs(log) do
    if e.ev == "request" then
      if e.purpose == "user" then
        total.requests = total.requests + 1
        req_t[#req_t + 1] = e.t
      else
        total.prefetches = total.prefetches + 1
      end
    elseif e.ev == "cancel" then
      total.cancels = total.cancels + 1
    elseif e.ev == "hit" then
      total.hits = total.hits + 1
    elseif e.ev == "adopt" then
      total.adopts = total.adopts + 1
    elseif e.ev == "show" and e.purpose == "user" then
      total.show_ms[#total.show_ms + 1] = e.ms
    elseif e.ev == "ui" then
      while keys_at[k] and keys_at[k] < e.t do
        k = k + 1
      end
      if shown and e.text == "" then
        total.hides = total.hides + 1
        -- Gone without a keystroke since it last changed: the user saw it flicker.
        if not (keys_at[k - 1] and keys_at[k - 1] > shown_at) then
          total.flickers = total.flickers + 1
        end
      end
      if e.text ~= "" then
        shown_at = e.t
      end
      shown = e.text ~= ""
    end
  end

  total.chars = total.chars + #truth
  total.typed = total.typed + stats.typed
  total.accepted = total.accepted + stats.accepted
  total.accepts = total.accepts + stats.accepts
  total.secs = total.secs + (now() - t_start) / 1000
  io.write(
    ("%-28s %4d chars  typed %4d  accepted %4d in %2d accepts  %5.1fs  %s\n"):format(
      ("%s:%d"):format(fn.file, fn.first),
      #truth,
      stats.typed,
      stats.accepted,
      stats.accepts,
      (now() - t_start) / 1000,
      ok and "ok" or "MISMATCH"
    )
  )
  io.flush()
end

vim.fn.jobstop(chan)

local per100 = function(x)
  return 100 * x / math.max(1, total.chars)
end
io.write(
  ("\n%s model=%s context=%s lines=%s confidence=%s wpm=%s reaction=%sms\n"):format(
    opts.suite,
    opts.model,
    opts.context,
    opts.lines,
    opts.confidence,
    opts.wpm,
    opts.reaction
  )
)
io.write(
  ("saved %.0f%% of keystrokes (accepts: %d all, %d line, %d word) | ghost on screen: %.0f%% correct, %.0f%% right then diverging, %.0f%% wrong from the start\n"):format(
    100 * (1 - total.typed / math.max(1, total.chars)),
    total.all,
    total.line,
    total.word,
    100 * total.good / math.max(1, total.obs),
    100 * (total.wrong - total.wrong_head) / math.max(1, total.obs),
    100 * total.wrong_head / math.max(1, total.obs)
  )
)
io.write(
  ("time to ghost p50 %.0fms p90 %.0fms | per 100 chars: %.1f requests, %.1f prefetches, %.1f cancels, %.1f hides, %.1f flickers | %d cache hits, %d adopted prefetches | %d mismatches | %.0fs\n"):format(
    lib.percentile(total.show_ms, 0.5),
    lib.percentile(total.show_ms, 0.9),
    per100(total.requests),
    per100(total.prefetches),
    per100(total.cancels),
    per100(total.hides),
    per100(total.flickers),
    total.hits,
    total.adopts,
    total.mismatch,
    total.secs
  )
)

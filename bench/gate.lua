-- Tries a gate on logged text without asking the server again. The logs must
-- hold uncut text, so they come from bench/replay.lua --confidence off.
--
-- bad/pt: chars shown from the first mistake on, per point. The log keeps only
-- the first 300 chars of the truth, so a longer ghost counts as wrong.
--
-- nvim -l bench/gate.lua --logs 'bench/out/x-*-mellum2-defs-block.jsonl' [--confidence 0.7] [--message 0.15|off]
local lib = dofile(vim.fs.dirname(vim.fs.abspath(arg[0])) .. "/lib.lua")
vim.opt.rtp:prepend(lib.root)

local config = require "tsugi.config"
local trim = require "tsugi.trim"

local opts = lib.args {
  logs = lib.root .. "/bench/out/*.jsonl",
  confidence = tostring(config.confidence),
  message = tostring(config.confidence_message),
}
local floor = assert(tonumber(opts.confidence), "--confidence needs a number")
local message = tonumber(opts.message)
local share = message and message < floor and math.log(floor) / math.log(message) or nil

---The part of an uncut ghost that passes the gate, cut the way tsugi.complete does it.
local function gated(point)
  local tokens, pos = {}, 0
  for i, t in ipairs(point.tokens) do
    tokens[i] = { at = pos + 1, len = t[1], logprob = t[2] }
    pos = pos + t[1]
  end
  local text = point.got
  local loose = share and trim.message(point.before or "", text) or nil
  local sure = trim.sure(tokens, #text, floor, loose, share)
  text = text:sub(1, sure):gsub("%s+$", "")
  return text:match "%S" and text or ""
end

io.write(("%-44s %4s %6s %6s %6s %6s %6s %6s\n"):format("log", "n", "shown", "ok", "wrong", "sv/pt", "len", "bad/pt"))

local function pct(x, of)
  return of > 0 and ("%5.0f%%"):format(100 * x / of) or "     -"
end

local files = vim.fn.glob(opts.logs, false, true)
table.sort(files)
for _, file in ipairs(files) do
  local rows, order = {}, {}
  for line in io.lines(file) do
    local point = vim.json.decode(line, { luanil = { object = true } })
    if not point.error then
      local name = vim.fs.basename(file):gsub("%.jsonl$", "") .. (point.tag and " " .. point.tag or "")
      if not rows[name] then
        rows[name] = { n = 0, shown = 0, ok = 0, wrong = 0, saved = 0, len = 0, bad = 0 }
        order[#order + 1] = name
      end
      local stats = rows[name]
      local text = gated(point)
      local s = lib.score(point.want, text)
      stats.n = stats.n + 1
      if s.kind ~= "empty" then
        stats.shown = stats.shown + 1
        stats[s.kind] = stats[s.kind] + 1
        stats.saved = stats.saved + s.saved
        stats.len = stats.len + #text
        stats.bad = stats.bad + s.bad
      end
    end
  end
  for _, name in ipairs(order) do
    local stats = rows[name]
    io.write(
      ("%-44s %4d %s %s %s %6.1f %6.1f %6.2f\n"):format(
        name,
        stats.n,
        pct(stats.shown, stats.n),
        pct(stats.ok, stats.shown),
        pct(stats.wrong, stats.shown),
        stats.saved / math.max(1, stats.n),
        stats.len / math.max(1, stats.shown),
        stats.bad / math.max(1, stats.n)
      )
    )
  end
end

-- Usage: nvim -l bench/run.lua [case-filter] [strategy-filter]
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.abspath(arg[0])))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local http = require "tsugi.http"
local format = require "tsugi.format"

local URL = os.getenv "TSUGI_URL" or "http://127.0.0.1:8080"
local case_filter, strategy_filter = arg[1], arg[2]

local strategies = {
  { name = "mellum-fim", model = "mellum-4b-dpo-all.Q8_0", build = format.fim.mellum, kinds = { fim = true } },
  { name = "sweep-fim", model = "sweep-next-edit-v2-7B-Q5_K_M", build = format.fim.qwen, kinds = { fim = true } },
  {
    name = "sweep-nes",
    model = "sweep-next-edit-v2-7B-Q5_K_M",
    build = format.nes.sweep,
    kinds = { fim = true, nes = true },
  },
  { name = "zeta-nes", model = "zeta-2.1.Q8_0", build = format.nes.zeta, kinds = { fim = true, nes = true } },
}

local function parse_case(c)
  local text = c.text:gsub("\n$", "")
  local s = text:find("█", 1, true)
  local before = text:sub(1, s - 1)
  text = before .. text:sub(s + #"█")
  local row = select(2, before:gsub("\n", "")) + 1
  local col = #before - (before:match ".*\n()" or 1) + 1
  return { path = c.path, lines = vim.split(text, "\n"), row = row, col = col, history = c.history or {} }
end

local function meaningful(a, b)
  return #vim.trim(a) + #vim.trim(b) > 6
end

---Index into old where new rejoins it after diverging, so the rest is a copy.
local function rejoin(old, new)
  local d
  for i = 1, #new do
    if new[i] ~= old[i] then
      d = i
      break
    end
  end
  local i = #new
  if not d or i - 1 <= d then
    return nil
  end
  for k = math.max(2, d + 1), #old do
    if new[i - 1] == old[k - 1] and new[i] == old[k] and meaningful(old[k - 1], old[k]) then
      return k
    end
  end
end

local function run(strategy, ctx)
  local req = strategy.build(ctx)
  local out = { text = "" }
  local t0 = vim.uv.hrtime()
  local ms = function()
    return (vim.uv.hrtime() - t0) / 1e6
  end
  local old = req.first and vim.list_slice(ctx.lines, req.first, req.last) or nil
  local done = false

  http.stream(URL .. "/completion", {
    model = strategy.model,
    prompt = req.prompt,
    n_predict = req.n_predict,
    stop = req.stop,
    temperature = 0,
    cache_prompt = true,
  }, function(msg)
    if msg.error then
      out.error = msg.error.message
      return
    end
    local piece = msg.content or ""
    if piece ~= "" and not out.ttft then
      out.ttft = ms()
    end
    out.text = out.text .. piece
    if not req.first and not out.line and out.text:find("\n", 1, true) then
      out.line = ms()
    end
    if old and not out.stop then
      local full = (req.prefill or "")
        .. out.text:gsub("^" .. vim.pesc(req.strip or ""), ""):gsub("<|user_cursor|>", "")
      local lines = vim.split(full, "\n")
      table.remove(lines)
      local k = rejoin(old, lines)
      if k then
        out.stop = ms()
        out.early = vim.list_extend(vim.list_slice(lines), vim.list_slice(old, k + 1))
      end
    end
    if msg.stop then
      out.timings = msg.timings
      out.tokens_cached = msg.tokens_cached
    end
  end, function()
    out.total = ms()
    done = true
  end)

  vim.wait(60000, function()
    return done
  end, 5)
  out.req, out.old = req, old
  return out
end

local function show(out)
  local req = out.req
  if out.error then
    return "  ERROR " .. out.error
  end
  if not req.first then
    return "  │ " .. out.text:gsub("\n", "\n  │ ")
  end
  local text = out.text:gsub("^" .. vim.pesc(req.strip or ""), "")
  if text:find "^<|marker_1|>" then
    return "  (no edit)"
  end
  text = (req.prefill or "") .. text:gsub("\n?<|marker_%d+|>.*$", ""):gsub("<|user_cursor|>", ""):gsub("\n$", "")
  local diff = vim.text.diff(table.concat(out.old, "\n") .. "\n", text .. "\n", { ctxlen = 0 })
  if diff == "" then
    return "  (no edit)"
  end
  local lossless = ""
  if out.early then
    lossless = table.concat(out.early, "\n") == text and "  early stop: lossless" or "  early stop: LOSSY"
  end
  return "  " .. diff:gsub("\n$", ""):gsub("\n", "\n  ") .. (lossless ~= "" and ("\n" .. lossless) or "")
end

local function fmt_ms(v)
  return v and ("%5.0f"):format(v) or "    -"
end

local cases = dofile(root .. "/bench/cases.lua")

local warmed = {}
for _, s in ipairs(strategies) do
  if not warmed[s.model] and (not strategy_filter or s.name:find(strategy_filter, 1, true)) then
    warmed[s.model] = true
    local t = vim.uv.hrtime()
    run({
      model = s.model,
      build = function()
        return { prompt = "x", stop = {}, n_predict = 1 }
      end,
    }, {})
    io.write(("warm %-32s %6.0f ms\n"):format(s.model, (vim.uv.hrtime() - t) / 1e6))
  end
end

for _, c in ipairs(cases) do
  if not case_filter or c.name:find(case_filter, 1, true) then
    local ctx = parse_case(c)
    io.write(("\n=== %s (%s)\n"):format(c.name, c.kind))
    for _, s in ipairs(strategies) do
      if s.kinds[c.kind] and (not strategy_filter or s.name:find(strategy_filter, 1, true)) then
        local cold = run(s, ctx)
        local warm = run(s, ctx)
        local t = cold.timings or {}
        io.write(
          ("%-14s ttft %s  line %s  stop %s  total %s | warm total %s | prompt %5d  gen %4d  %4.0f tok/s\n"):format(
            s.name,
            fmt_ms(cold.ttft),
            fmt_ms(cold.line),
            fmt_ms(cold.stop),
            fmt_ms(cold.total),
            fmt_ms(warm.total),
            (t.prompt_n or 0),
            (t.predicted_n or 0),
            (t.predicted_per_second or 0)
          )
        )
        io.write(show(cold), "\n")
      end
    end
  end
end

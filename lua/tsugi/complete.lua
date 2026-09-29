local format = require("tsugi.format")
local http = require("tsugi.http")
local trim = require("tsugi.trim")

local M = {}

local function confidence(tokens, len)
  local min, sum, n = 0, 0, 0
  for _, t in ipairs(tokens) do
    if t.at > len then
      break
    end
    min = math.min(min, t.logprob)
    sum = sum + t.logprob
    n = n + 1
  end
  if n == 0 then
    return nil
  end
  return { min = min, mean = sum / n, first = tokens[1].logprob }
end

---@class tsugi.Progress
---@field ttft? number ms to first token
---@field timings? table llama.cpp timings, only when the model stopped on its own
---@field prompt_chars integer
---@field error? string
---@field confidence? { min: number, mean: number, first: number } token logprobs over the kept text

---Starts a FIM request and reports trimmed text on the main loop. Generation is
---cancelled as soon as the stop rules say the rest would be thrown away.
---@param url string
---@param model tsugi.Model
---@param ctx tsugi.Context
---@param limit "block"|integer see tsugi.trim
---@param cb fun(text: string, done: boolean, info: tsugi.Progress)
---@return vim.SystemObj
function M.fim(url, model, ctx, limit, cb)
  local req = format.fim[model.fim](ctx)
  local stop = vim.list_extend({}, req.stop)
  if ctx.lines[ctx.row]:sub(ctx.col + 1):match("%S") then
    stop[#stop + 1] = "\n"
  end

  local t0 = vim.uv.hrtime()
  local info = { prompt_chars = #req.prompt }
  local raw, finished = "", false
  local tokens, pos = {}, 0
  local handle
  handle = http.stream(url .. "/completion", {
    model = model.id,
    prompt = req.prompt,
    n_predict = req.n_predict,
    stop = stop,
    temperature = 0,
    cache_prompt = true,
    n_probs = 1,
  }, function(msg)
    vim.schedule(function()
      if finished then
        return
      end
      if msg.error then
        finished = true
        info.error = msg.error.message
        return cb("", true, info)
      end
      local piece = msg.content or ""
      if piece ~= "" and not info.ttft then
        info.ttft = (vim.uv.hrtime() - t0) / 1e6
      end
      for _, p in ipairs(msg.completion_probabilities or {}) do
        tokens[#tokens + 1] = { at = pos + 1, logprob = p.logprob }
        pos = pos + #p.token
      end
      raw = raw .. piece
      local final = msg.stop == true
      local text, done = trim.fim(raw, ctx.lines, ctx.row, ctx.col, final, limit)
      info.confidence = confidence(tokens, #text)
      if done or final then
        finished = true
        info.timings = msg.timings
        if not final and not handle:is_closing() then
          handle:kill(15)
        end
      end
      cb(text, finished, info)
    end)
  end, function()
    vim.schedule(function()
      if not finished then
        finished = true
        info.error = "connection closed"
        cb("", true, info)
      end
    end)
  end)
  return handle
end

return M

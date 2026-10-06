local format = require "tsugi.format"
local http = require "tsugi.http"
local trim = require "tsugi.trim"

local M = {}

---@class tsugi.Progress
---@field ttft? number ms to first token
---@field timings? table llama.cpp timings, only when the model stopped on its own
---@field prompt_chars integer
---@field error? string
---@field cut? boolean the confidence floor shortened the text
---@field tokens { at: integer, len: integer, logprob: number }[] every token streamed so far

---@class tsugi.Limits
---@field lines "block"|integer see tsugi.trim
---@field confidence number|false see tsugi.Config

---Starts a FIM request and reports trimmed text on the main loop. Generation is
---cancelled as soon as the rest would be thrown away: the stop rules ended the
---text, or the model is no longer sure enough of it.
---@param url string
---@param model tsugi.Model
---@param ctx tsugi.Context
---@param limits tsugi.Limits
---@param cb fun(text: string, done: boolean, info: tsugi.Progress)
---@return vim.SystemObj
function M.fim(url, model, ctx, limits, cb)
  local req = format.fim[model.fim](ctx)
  local stop = vim.list_extend({}, req.stop)
  if ctx.lines[ctx.row]:sub(ctx.col + 1):match "%S" then
    stop[#stop + 1] = "\n"
  end

  local t0 = vim.uv.hrtime()
  local tokens, pos = {}, 0
  local info = { prompt_chars = #req.prompt, tokens = tokens }
  local raw, finished = "", false
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
        tokens[#tokens + 1] = { at = pos + 1, len = #p.token, logprob = p.logprob }
        pos = pos + #p.token
      end
      raw = raw .. piece
      local final = msg.stop == true
      local text, done = trim.fim(raw, ctx.lines, ctx.row, ctx.col, final, limits.lines)
      if limits.confidence then
        local sure = trim.sure(tokens, #text, limits.confidence)
        if sure < #text then
          text = text:sub(1, sure):gsub("%s+$", "")
          done, info.cut = true, true
        end
      end
      if (done or final) and not text:match "%S" then
        text = ""
      end
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

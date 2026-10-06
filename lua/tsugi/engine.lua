local config = require "tsugi.config"
local context = require "tsugi.context"
local complete = require "tsugi.complete"
local format = require "tsugi.format"
local stats = require "tsugi.stats"
local trim = require "tsugi.trim"
local ui = require "tsugi.ui"

local M = {}

---@class tsugi.Suggestion
---@field buf integer
---@field row integer absolute row the completion starts at
---@field col integer
---@field after string rest of the line at the origin
---@field key string
---@field ctx table
---@field text string
---@field done boolean
---@field purpose "user"|"prefetch"|"cache"
---@field t0 number
---@field ttft? number
---@field shown? boolean
---@field handle? vim.SystemObj
---@field killed? boolean

---@type tsugi.Suggestion?
local active
---@type tsugi.Suggestion?
local prefetch
local cache, order = {}, {}
local memo = {}
local hidden = false
local timer = assert(vim.uv.new_timer())

---Hook for benchmarks and stats: fun(event: string, data: table)
M.on_event = nil

local function now()
  return vim.uv.hrtime() / 1e6
end

local function emit(name, data)
  data = data or {}
  stats.record(name, data)
  if M.on_event then
    M.on_event(name, data)
  end
end

local function remember(key, text)
  if cache[key] == nil then
    order[#order + 1] = key
    if #order > 256 then
      cache[table.remove(order, 1)] = nil
    end
  end
  cache[key] = text
end

local function key_of(lines, row, col)
  local line = lines[row]
  return table.concat(lines, "\n", math.max(1, row - 30), row - 1)
    .. "\n"
    .. line:sub(1, col)
    .. "\1"
    .. line:sub(col + 1)
    .. "\n"
    .. table.concat(lines, "\n", row + 1, math.min(#lines, row + 10))
end

local function snapshot()
  local buf = vim.api.nvim_get_current_buf()
  local cur = vim.api.nvim_win_get_cursor(0)
  local below = format.suffix[config.models[config.model].fim]
  local first, last = context.window(cur[1], vim.api.nvim_buf_line_count(buf), 120, below)
  return {
    buf = buf,
    path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":."),
    lines = vim.api.nvim_buf_get_lines(buf, first - 1, last, false),
    row = cur[1] - first + 1,
    col = cur[2],
    first = first,
  }
end

-- Chunks stay put while the cursor stays near, so the prompt head stays cached.
local function chunks_for(ctx)
  local row = ctx.first + ctx.row - 1
  if memo.buf == ctx.buf and memo.row and math.abs(memo.row - row) < 8 then
    return memo.chunks
  end
  local chunks = context.collect(config.context, { buf = ctx.buf, lines = ctx.lines, row = ctx.row })
  memo = { buf = ctx.buf, row = row, chunks = chunks }
  return chunks
end

local function kill(s)
  s.killed = true
  if s.handle and not s.handle:is_closing() then
    s.handle:kill(15)
  end
end

---Text still to be shown, given what was typed since the suggestion started.
---Returns nil when the buffer no longer agrees with the suggestion.
---@param s tsugi.Suggestion
---@return string?
local function remaining(s)
  if vim.api.nvim_get_current_buf() ~= s.buf then
    return nil
  end
  local cur = vim.api.nvim_win_get_cursor(0)
  local row, col = cur[1], cur[2]
  if row < s.row or (row == s.row and col < s.col) then
    return nil
  end
  local line = vim.api.nvim_buf_get_lines(s.buf, row - 1, row, false)[1] or ""
  local after = line:sub(col + 1)
  -- An autopairs plugin may have put closers right after the cursor since.
  local closers = after:sub(1, #after - #s.after)
  if not vim.endswith(after, s.after) or closers:match "[^%)%]}\"'`]" then
    return nil
  end
  local typed = table.concat(vim.api.nvim_buf_get_text(s.buf, s.row - 1, s.col, row - 1, col, {}), "\n")
  if #typed > #s.text then
    if not s.done and vim.startswith(typed, s.text) then
      return ""
    end
    return nil
  end
  if s.text:sub(1, #typed) ~= typed then
    return nil
  end
  return (trim.until_closer(s.text:sub(#typed + 1), closers))
end

local function discard()
  if not active then
    return
  end
  if not active.done then
    kill(active)
    emit("cancel", { purpose = active.purpose, ms = now() - active.t0 })
  end
  ui.clear(active.buf)
  active = nil
end

local function render()
  if not active then
    return
  end
  local rest = remaining(active)
  if not rest then
    return discard()
  end
  if hidden or not rest:match "%S" then
    return ui.clear(active.buf)
  end
  local cur = vim.api.nvim_win_get_cursor(0)
  ui.show(active.buf, cur[1], cur[2], rest)
  if not active.shown then
    active.shown = true
    emit("show", { purpose = active.purpose, ms = now() - active.t0, text = rest })
  end
end

local start

local function maybe_prefetch()
  local s = active
  if not config.prefetch or not s or not s.done or s.text == "" then
    return
  end
  if prefetch and not prefetch.done then
    return
  end
  local ctx = s.ctx
  local line = ctx.lines[ctx.row]
  local ins = vim.split(s.text, "\n", { plain = true })
  ins[1] = line:sub(1, ctx.col) .. ins[1]
  local row = ctx.row + #ins - 1
  local col = #ins[#ins]
  ins[#ins] = ins[#ins] .. line:sub(ctx.col + 1)
  local lines = vim.list_slice(ctx.lines, 1, ctx.row - 1)
  vim.list_extend(lines, ins)
  vim.list_extend(lines, ctx.lines, ctx.row + 1)
  local key = key_of(lines, row, col)
  if cache[key] ~= nil then
    return
  end
  prefetch = start({
    buf = ctx.buf,
    path = ctx.path,
    lines = lines,
    row = row,
    col = col,
    first = ctx.first,
    chunks = ctx.chunks,
  }, "prefetch", key)
end

local function on_update(s, text, done, info)
  if s.done or s.killed then
    return
  end
  s.ttft = info.ttft
  -- The first line grows token by token. Later lines wait until they are whole,
  -- since a stop rule may still drop them.
  s.text = done and text or (text:match "^(.*)\n" or text)
  if done then
    s.done = true
    if info.error then
      emit("error", { message = info.error })
    else
      remember(s.key, text)
      emit("done", {
        purpose = s.purpose,
        ms = now() - s.t0,
        ttft = s.ttft,
        text = text,
        cut = info.cut,
        timings = info.timings,
      })
    end
  end
  if s == active then
    render()
    if s.done then
      maybe_prefetch()
    end
  end
end

---@return tsugi.Suggestion
function start(ctx, purpose, key)
  ctx.chunks = ctx.chunks or chunks_for(ctx)
  local line = ctx.lines[ctx.row]
  ---@type tsugi.Suggestion
  local s = {
    buf = ctx.buf,
    row = ctx.first + ctx.row - 1,
    col = ctx.col,
    after = line:sub(ctx.col + 1),
    key = key,
    ctx = ctx,
    text = "",
    done = false,
    purpose = purpose,
    t0 = now(),
  }
  emit("request", { purpose = purpose })
  local limits = { lines = config.lines, confidence = config.confidence }
  s.handle = complete.fim(config.url, config.models[config.model], ctx, limits, function(text, done, info)
    on_update(s, text, done, info)
  end)
  return s
end

local function inserting()
  return vim.api.nvim_get_mode().mode:sub(1, 1) == "i"
end

function M.on_change()
  if not inserting() or vim.bo.buftype ~= "" then
    return
  end
  if active then
    local rest = remaining(active)
    if rest and (rest ~= "" or not active.done) then
      return render()
    end
    discard()
  end

  local ctx = snapshot()
  local key = key_of(ctx.lines, ctx.row, ctx.col)
  local hit = cache[key]
  if hit ~= nil then
    local line = ctx.lines[ctx.row]
    active = {
      buf = ctx.buf,
      row = ctx.first + ctx.row - 1,
      col = ctx.col,
      after = line:sub(ctx.col + 1),
      key = key,
      ctx = ctx,
      text = hit,
      done = true,
      purpose = "cache",
      t0 = now(),
    }
    emit "hit"
    render()
    maybe_prefetch()
    return
  end

  if prefetch then
    if prefetch.key == key and not prefetch.done then
      active, prefetch = prefetch, nil
      emit "adopt"
      return render()
    end
    if not prefetch.done then
      kill(prefetch)
    end
    prefetch = nil
  end

  timer:stop()
  timer:start(
    config.debounce,
    0,
    vim.schedule_wrap(function()
      if not inserting() or active then
        return
      end
      local c = snapshot()
      if key_of(c.lines, c.row, c.col) == key then
        active = start(c, "user", key)
      end
    end)
  )
end

---@param kind "all"|"word"|"line"
---@return boolean accepted
function M.accept(kind)
  local rest = M.visible()
  if not active or not rest then
    return false
  end
  local take = rest
  if kind == "word" then
    take = rest:match "^%s*[%w_]+" or rest:match "^%s*[^%w_%s]+" or rest
  elseif kind == "line" then
    take = rest:match "^\n?[^\n]*"
  end
  local buf = active.buf
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local lines = vim.split(take, "\n", { plain = true })
  local function insert()
    vim.api.nvim_buf_set_text(buf, row - 1, col, row - 1, col, lines)
    vim.api.nvim_win_set_cursor(0, { row + #lines - 1, (#lines == 1 and col or 0) + #lines[#lines] })
    emit("accept", { kind = kind, chars = #take })
    render()
  end
  -- Expr mappings (blink keymaps) hold the textlock, so insert right after.
  if not pcall(insert) then
    vim.schedule(insert)
  end
  return true
end

---Hides the ghost while a completion menu is open, without dropping it.
---@param hide boolean
function M.hide(hide)
  hidden = hide
  render()
end

function M.dismiss()
  timer:stop()
  discard()
  if prefetch and not prefetch.done then
    kill(prefetch)
  end
  prefetch = nil
end

---The ghost on screen, if any.
---@return string?
function M.visible()
  if not active or hidden then
    return nil
  end
  local rest = remaining(active)
  return rest and rest:match "%S" and rest or nil
end

function M.reset()
  M.dismiss()
  cache, order, memo = {}, {}, {}
end

return M

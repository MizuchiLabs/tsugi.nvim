local M = {}

---Accepts the visible suggestion. Returns false when there is none, so it can
---sit first in another plugin's key chain (blink: return it from a keymap fn).
---@param kind? "all"|"word"|"line"
---@return boolean
function M.accept(kind)
  return require("tsugi.engine").accept(kind or "all")
end

---@param opts? table see tsugi.config
function M.setup(opts)
  local config = require("tsugi.config")
  local context = require("tsugi.context")
  local engine = require("tsugi.engine")
  config.setup(opts)

  local group = vim.api.nvim_create_augroup("tsugi", { clear = true })
  vim.api.nvim_create_autocmd({ "TextChangedI", "CursorMovedI" }, {
    group = group,
    callback = engine.on_change,
  })
  vim.api.nvim_create_autocmd({ "InsertLeave", "BufLeave" }, {
    group = group,
    callback = engine.dismiss,
  })
  vim.api.nvim_create_autocmd({ "BufEnter", "InsertLeave", "TextYankPost", "BufWritePost" }, {
    group = group,
    callback = function(ev)
      if vim.api.nvim_get_current_buf() == ev.buf then
        context.touch(ev.buf, vim.api.nvim_win_get_cursor(0)[1])
      end
    end,
  })

  -- An open menu alone leaves the ghost up. Only a selected item, which blink or
  -- the native menu previews in place, takes it down.
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = { "BlinkCmpListSelect", "BlinkCmpHide" },
    callback = function(ev)
      engine.hide(ev.match == "BlinkCmpListSelect" and ev.data and ev.data.idx ~= nil)
    end,
  })
  vim.api.nvim_create_autocmd({ "CompleteChanged", "CompleteDone" }, {
    group = group,
    callback = function(ev)
      engine.hide(ev.event == "CompleteChanged" and not vim.tbl_isempty(vim.v.event.completed_item or {}))
    end,
  })

  local function map(lhs, kind)
    if not lhs or lhs == "" then
      return
    end
    local alt = lhs:match("^<[MA]%-") ~= nil
    vim.keymap.set("i", lhs, function()
      if not engine.accept(kind) and not alt then
        vim.api.nvim_feedkeys(vim.keycode(lhs), "n", false)
      end
    end, { desc = "tsugi: accept " .. kind })
  end
  map(config.keymaps.accept, "all")
  map(config.keymaps.accept_word, "word")
  map(config.keymaps.accept_line, "line")
  if config.keymaps.dismiss then
    vim.keymap.set("i", config.keymaps.dismiss, engine.dismiss, { desc = "tsugi: dismiss" })
  end

  vim.api.nvim_create_user_command("Tsugi", function(cmd)
    local sub, rest = cmd.fargs[1], vim.list_slice(cmd.fargs, 2)
    if sub == "model" and config.models[rest[1]] then
      config.model = rest[1]
      engine.reset()
    elseif sub == "context" and #rest > 0 then
      config.context = rest
      engine.reset()
    elseif sub == "stats" then
      vim.notify(require("tsugi.stats").report())
    else
      vim.notify(("tsugi: model=%s context=%s"):format(config.model, table.concat(config.context, ",")))
    end
  end, {
    nargs = "*",
    complete = function(_, line)
      local words = vim.split(line, "%s+", { trimempty = true })
      if #words <= 2 and not line:match("%s%S+%s") then
        return { "model", "context", "stats" }
      end
      if words[2] == "model" then
        return vim.tbl_keys(config.models)
      end
      return vim.tbl_keys(context.strategies)
    end,
  })
end

return M

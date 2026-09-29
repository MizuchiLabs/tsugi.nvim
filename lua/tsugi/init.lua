local M = {}

---Accepts the visible suggestion. Returns false when there is none, so it can
---sit first in another plugin's key chain (blink: return it from a keymap fn).
---@param kind? "all"|"word"|"line"
---@return boolean
function M.accept(kind)
  return require("tsugi.engine").accept(kind or "all")
end

---Switches to another entry of `models` and loads it on the server right away,
---so the first suggestion doesn't wait for a cold start. Without a name it
---opens a picker.
---@param name? string
function M.use_model(name)
  local config = require "tsugi.config"
  if not name then
    local names = vim.tbl_keys(config.models)
    table.sort(names)
    vim.ui.select(names, {
      prompt = "tsugi model",
      format_item = function(n)
        return ("%s%s  %s"):format(n == config.model and "* " or "  ", n, config.models[n].id)
      end,
    }, function(choice)
      if choice then
        M.use_model(choice)
      end
    end)
    return
  end
  local model = config.models[name]
  if not model then
    return vim.notify("tsugi: unknown model " .. name, vim.log.levels.WARN)
  end
  config.model = name
  require("tsugi.engine").reset()
  vim.system({
    "curl",
    "-sf",
    config.url .. "/completion",
    "-H",
    "content-type: application/json",
    "-d",
    vim.json.encode { model = model.id, prompt = "\n", n_predict = 1 },
  }, {}, function(res)
    vim.schedule(function()
      vim.notify(("tsugi: %s %s"):format(name, res.code == 0 and "ready" or "failed to load"))
    end)
  end)
end

---@param opts? table see tsugi.config
function M.setup(opts)
  local config = require "tsugi.config"
  local context = require "tsugi.context"
  local engine = require "tsugi.engine"
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
      engine.hide(ev.match == "BlinkCmpListSelect" and (ev.data or {}).idx ~= nil)
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
    local alt = lhs:match "^<[MA]%-" ~= nil
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
    if sub == "model" then
      M.use_model(rest[1])
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
      if #words <= 2 and not line:match "%s%S+%s" then
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

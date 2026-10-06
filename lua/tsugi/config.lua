---@class tsugi.Model
---@field id string model name sent to llama-server (router mode picks by it)
---@field fim? "mellum"|"qwen"|"seed" prompt format for inline completion

---@class tsugi.Config
local defaults = {
  url = "http://127.0.0.1:8080",
  model = "sweep",
  ---@type table<string, tsugi.Model>
  models = {
    mellum = { id = "mellum-4b-dpo-all.Q8_0", fim = "mellum" },
    mellum2 = { id = "Mellum2-12B-A2.5B-Base.Q4_K_M", fim = "mellum" },
    seed = { id = "Seed-Coder-8B-Base.Q8_0", fim = "seed" },
    sweep = { id = "sweep-next-edit-v2-7B-Q5_K_M", fim = "qwen" },
  },
  ---Strategies from tsugi.context, combined in order: "none", "recent", "similar", "defs".
  context = { "defs" },
  ---"block": one statement, or the whole block it opens. A number: up to that many lines.
  lines = "block",
  ---How sure the model must be that the shown text is right, as a probability
  ---from its own token probabilities. The ghost ends before the first token that
  ---would take it below. false shows everything.
  ---@type number|false
  confidence = 0.7,
  debounce = 20,
  prefetch = true,
  ---Set a key to false to leave it unmapped. With nothing to accept, the key does
  ---what it normally does, except Alt keys, which terminals send as Esc+key.
  keymaps = {
    accept = "<M-f>",
    accept_word = "<C-Right>",
    accept_line = "<C-l>",
    dismiss = "<C-]>",
  },
}

---@class tsugi.ConfigModule: tsugi.Config
local M = vim.deepcopy(defaults)

---@param opts? table
function M.setup(opts)
  local merged = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  for k, v in pairs(merged) do
    M[k] = v
  end
end

return M

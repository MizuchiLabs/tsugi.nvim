local M = {}

local ns = vim.api.nvim_create_namespace "tsugi"
vim.api.nvim_set_hl(0, "TsugiGhost", { link = "Comment", default = true })

local function expand(s, buf)
  local ts = vim.bo[buf].tabstop
  return (s:gsub("\t", string.rep(" ", ts)))
end

---@param buf integer
---@param row integer 1-based
---@param col integer 0-based
---@param text string
function M.show(buf, row, col, text)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  if text == "" then
    return
  end
  local lines = vim.split(text, "\n", { plain = true })
  local virt_lines = {}
  for i = 2, #lines do
    virt_lines[#virt_lines + 1] = { { expand(lines[i], buf), "TsugiGhost" } }
  end
  vim.api.nvim_buf_set_extmark(buf, ns, row - 1, col, {
    virt_text = { { expand(lines[1], buf), "TsugiGhost" } },
    virt_text_pos = "inline",
    virt_lines = #virt_lines > 0 and virt_lines or nil,
    hl_mode = "combine",
  })
end

---@param buf? integer
function M.clear(buf)
  if buf and vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  end
end

M.ns = ns

return M

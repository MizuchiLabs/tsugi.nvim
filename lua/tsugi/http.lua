local M = {}

---Streams a llama.cpp /completion request. Callbacks run in a fast event context.
---@param url string
---@param body table
---@param on_chunk fun(msg: table)
---@param on_exit fun(code: integer)
---@return vim.SystemObj
function M.stream(url, body, on_chunk, on_exit)
  body.stream = true
  local pending = ""
  return vim.system({
    "curl",
    "-sN",
    "-X",
    "POST",
    url,
    "-H",
    "content-type: application/json",
    "--data-binary",
    "@-",
  }, {
    stdin = vim.json.encode(body),
    stdout = function(_, data)
      if not data then
        return
      end
      pending = pending .. data
      while true do
        local nl = pending:find("\n", 1, true)
        if not nl then
          break
        end
        local payload = pending:sub(1, nl - 1):match("^data: (.+)")
        pending = pending:sub(nl + 1)
        if payload then
          local ok, msg = pcall(vim.json.decode, payload)
          if ok then
            on_chunk(msg)
          end
        end
      end
    end,
  }, function(res)
    on_exit(res.code)
  end)
end

return M

local M = {}

local function indent(s)
  return #s:match "^%s*"
end

local function blank(s)
  return s:match "^%s*$" ~= nil
end

local function opens(s)
  return s:match "[{(%[]%s*$" ~= nil
end

---Cuts raw (possibly still streaming) FIM output down to what is worth showing.
---`limit` "block" keeps one statement, or the whole block when the statement
---opens one. A number keeps up to that many lines.
---@param raw string
---@param lines string[] buffer lines
---@param row integer 1-based
---@param col integer 0-based
---@param final boolean true when the model stopped on its own
---@param limit "block"|integer
---@return string text
---@return boolean done no point generating further
function M.fim(raw, lines, row, col, final, limit)
  local line = lines[row] or ""
  local rest = line:sub(col + 1)

  if not blank(rest) then
    local nl = raw:find("\n", 1, true)
    local text = nl and raw:sub(1, nl - 1) or raw
    local tail = vim.trim(rest)
    if (nl or final) and #tail >= 4 and vim.endswith(text, tail) then
      text = text:sub(1, -#tail - 1)
    end
    return text, nl ~= nil
  end

  local out = vim.split(raw, "\n", { plain = true })
  local complete = #out
  if not final then
    complete = complete - 1
  end

  local base = indent(line)
  local next_line
  for i = row + 1, #lines do
    if not blank(lines[i]) then
      if lines[i]:match "%w" then
        next_line = lines[i]:gsub("%s+$", "")
      end
      break
    end
  end

  local block = limit == "block"
  local max = block and 12 or limit
  local head
  local keep = {}
  local function cut()
    return table.concat(keep, "\n"), true
  end

  for i, l in ipairs(out) do
    if i > complete then
      keep[#keep + 1] = l
      return table.concat(keep, "\n"), false
    end
    if i > 1 then
      local stop = (blank(l) and #keep > 1)
        or indent(l) < base
        or (next_line and l:gsub("%s+$", "") == next_line)
        or (i > 2 and l == out[i - 1] and not blank(l))
      if stop then
        return cut()
      end
    end
    keep[#keep + 1] = l:gsub("%s+$", "")
    if block and not blank(l) then
      local ind = i == 1 and base or indent(l)
      if not head then
        head = ind
        if not opens(l) then
          return cut()
        end
      elseif ind == head and l:match "^%s*[})%]]" then
        return cut()
      end
    end
    if #keep >= max then
      return cut()
    end
  end
  local text = table.concat(keep, "\n")
  if final then
    text = text:gsub("%s+$", "")
  end
  return text, final
end

return M

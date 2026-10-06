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

local openers = { [")"] = "(", ["]"] = "[", ["}"] = "{" }
local quotes = { ["\""] = true, ["'"] = true, ["`"] = true }

---Cuts text before it repeats the closer that already sits after the cursor,
---like the one an autopairs plugin puts there: a bracket the text did not open
---itself, or the quote that ends the string the cursor is in.
---@param text string
---@param tail string text after the cursor
---@return string text
---@return boolean cut
function M.until_closer(text, tail)
  local closer = tail:match "^%s*(.)"
  local opener = openers[closer]
  if not opener and not quotes[closer] then
    return text, false
  end
  local depth, i = 0, 1
  while i <= #text do
    local c = text:sub(i, i)
    if c == "\\" then
      i = i + 1
    elseif c == closer then
      if depth == 0 then
        return text:sub(1, i - 1), true
      end
      depth = depth - 1
    elseif c == opener then
      depth = depth + 1
    end
    i = i + 1
  end
  return text, false
end

---How much of the text the model is sure about: the longest run of tokens from
---the start whose joint probability stays at or above `floor`. A later token
---can only lower it, so the cut is final even while streaming. Text that came
---without a token probability is not trusted.
---@param tokens { at: integer, len: integer, logprob: number }[] `at` is the 1-based start in the raw output
---@param len integer length of the kept text
---@param floor number probability from 0 to 1
---@return integer chars
function M.sure(tokens, len, floor)
  local limit, sum, chars = math.log(floor), 0, 0
  for _, t in ipairs(tokens) do
    if t.at > len then
      return len
    end
    sum = sum + t.logprob
    if sum < limit then
      return chars
    end
    chars = math.min(len, t.at + t.len - 1)
  end
  return chars
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
    local inside, closed = M.until_closer(text, rest)
    if closed then
      return inside, true
    end
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

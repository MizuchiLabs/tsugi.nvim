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

local reporting = {
  "log",
  "error",
  "warn",
  "info",
  "debug",
  "print",
  "fatal",
  "panic",
  "notify",
  "toast",
  "throw",
  "raise",
  "fail",
  "bail",
}

---Whether code names something that logs or reports an error, like
---`slog.Error(` or `throw new Error(`.
---@param code string
---@return boolean
function M.reports(code)
  code = code:lower()
  for _, word in ipairs(reporting) do
    if code:find(word, 1, true) then
      return true
    end
  end
  return false
end

---Finds the message text in `text`: what is inside the first string of a call
---that logs or reports an error. A message has many right wordings, so the
---gate counts doubt about it for less. Judged line by line, so a call that
---starts on an earlier line is not seen.
---@param before string the cursor line up to the cursor
---@param text string
---@return table<integer, true> set of 1-based byte positions in text, the closing quote included
function M.message(before, text)
  local s, out = before .. text, {}
  local quote, loose, bol = nil, false, 1
  local stack = {}
  local i = 1
  while i <= #s do
    local c = s:sub(i, i)
    local skip = c == "\\" and 1 or 0
    if quote and loose then
      for at = math.max(1, i - #before), i - #before + skip do
        out[at] = true
      end
    end
    if c == "\n" then
      quote, bol, stack = nil, i + 1, {}
    elseif skip == 1 then
      i = i + 1
    elseif quote then
      if c == quote then
        quote = nil
      end
    elseif quotes[c] then
      local call = stack[#stack]
      quote = c
      loose = call ~= nil and call.open == "(" and not call.string and M.reports(s:sub(bol, i - 1))
      if call then
        call.string = true
      end
    elseif openers[c] and #stack > 0 and stack[#stack].open == openers[c] then
      stack[#stack] = nil
    elseif c == "(" or c == "[" or c == "{" then
      stack[#stack + 1] = { open = c }
    end
    i = i + 1
  end
  return out
end

---How much of the text the model is sure about: the longest run of tokens from
---the start whose joint probability stays at or above `floor`. A later token
---can only lower it, so the cut is final even while streaming. Text that came
---without a token probability is not trusted.
---@param tokens { at: integer, len: integer, logprob: number }[] `at` is the 1-based start in the raw output
---@param len integer length of the kept text
---@param floor number probability from 0 to 1
---@param loose? table<integer, true> starts of tokens whose doubt counts for only `share`
---@param share? number from 0 to 1
---@return integer chars
function M.sure(tokens, len, floor, loose, share)
  local limit, sum, chars = math.log(floor), 0, 0
  for _, t in ipairs(tokens) do
    if t.at > len then
      return len
    end
    sum = sum + t.logprob * (loose and loose[t.at] and share or 1)
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

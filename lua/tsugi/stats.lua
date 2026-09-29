local M = {}

local counts, show_ms, accepted = {}, {}, 0

---@param name string
---@param data table
function M.record(name, data)
  local key = data.purpose and (name .. ":" .. data.purpose) or name
  counts[key] = (counts[key] or 0) + 1
  if name == "show" and data.purpose == "user" then
    show_ms[#show_ms + 1] = data.ms
    if #show_ms > 500 then
      table.remove(show_ms, 1)
    end
  elseif name == "accept" then
    accepted = accepted + data.chars
  end
end

local function pct(xs, p)
  if #xs == 0 then
    return 0
  end
  local s = vim.list_slice(xs)
  table.sort(s)
  return s[math.max(1, math.ceil(#s * p))]
end

function M.report()
  local c = function(k)
    return counts[k] or 0
  end
  local shown = c("show:user") + c("show:prefetch") + c("hit")
  return table.concat({
    ("requests %d, prefetches %d, cancelled %d"):format(c("request:user"), c("request:prefetch"), c("cancel:user")),
    ("ghosts shown %d, accepted %d (%d chars), cache hits %d, prefetch adopted %d"):format(
      shown,
      c("accept"),
      accepted,
      c("hit"),
      c("adopt")
    ),
    ("time to ghost p50 %.0fms, p90 %.0fms"):format(pct(show_ms, 0.5), pct(show_ms, 0.9)),
  }, "\n")
end

function M.reset()
  counts, show_ms, accepted = {}, {}, 0
end

return M

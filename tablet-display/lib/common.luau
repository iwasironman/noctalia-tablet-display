--!nonstrict
-- Shared by the panel, bar widget and shortcut.

local M = {}

M.STATE_KEY = "td_state"
M.COMMAND_KEY = "td_command"
M.PANEL_ID = "iwasironman/tablet-display:panel"

local counter = 0

-- Asks the service to run an action. Each request carries a unique serial,
-- because every entry is its own VM with its own counter.
function M.send(action, extra)
  counter += 1
  local command = { action = action, serial = `{noctalia.nowMs()}-{counter}-{math.random(1, 1000000)}` }
  if type(extra) == "table" then
    for k, v in pairs(extra) do
      command[k] = v
    end
  end
  noctalia.state.set(M.COMMAND_KEY, command)
end

function M.snapshot()
  local s = noctalia.state.get(M.STATE_KEY)
  if type(s) ~= "table" then
    return { loading = true, mode = "off" }
  end
  return s
end

function M.isActive(s)
  return s.mode == "extend" or s.mode == "mirror"
end

local function hz(r)
  return tostring(math.floor((tonumber(r) or 0) + 0.5))
end

-- One line describing what is going on.
function M.statusLine(s)
  if s.loading then
    return "Loading…"
  end
  if s.available == false then
    return "Control script failed"
  end
  local pending = s.pending or ""
  if pending == "extend" then return "Adding the tablet display…" end
  if pending == "mirror" then return "Starting to mirror…" end
  if pending == "off" then return "Turning off…" end
  if s.mode == "extend" then
    local m = s.monitor
    if type(m) == "table" then
      return `Extended on {m.name} · {m.width}×{m.height} @ {hz(m.refresh)} Hz`
    end
    return "Extended"
  elseif s.mode == "mirror" then
    return `Mirroring {s.target or "?"}`
  end
  return "Off"
end

function M.clientLine(s)
  local c = s.client
  if type(c) == "table" and c.width then
    return `Moonlight connected · {c.width}×{c.height} @ {c.fps} fps`
  end
  if M.isActive(s) then
    return "Waiting for Moonlight to connect"
  end
  return ""
end

return M

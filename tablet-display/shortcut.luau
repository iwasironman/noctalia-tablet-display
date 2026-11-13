--!nonstrict
-- Control-center tile: Extend on/off.

local common = require("./lib/common.luau")

local snapshot = common.snapshot()

local function render()
  local active = common.isActive(snapshot)
  local pending = (snapshot.pending or "") ~= ""
  shortcut.setLabel(active and (snapshot.mode == "mirror" and "Mirroring" or "Tablet on") or "Tablet")
  shortcut.setIcon("device-tablet")
  shortcut.setActive(active)
  shortcut.setEnabled(not pending and snapshot.installed ~= false)
end

noctalia.state.watch(common.STATE_KEY, function(value)
  if type(value) == "table" then
    snapshot = value
    render()
  end
end)

render()

function onClick()
  common.send(common.isActive(snapshot) and "off" or "extend")
end

function onRightClick()
  noctalia.togglePanel(common.PANEL_ID)
end

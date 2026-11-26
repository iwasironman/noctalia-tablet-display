--!nonstrict
-- Tablet Display service: the only entry that runs the control script.
-- It polls `tablet-display-ctl state`, publishes the snapshot for the panel,
-- widget and shortcut, runs the commands they send, and pushes the plugin
-- settings to the script whenever they change.

local STATE_KEY = "td_state"
local COMMAND_KEY = "td_command"

local ACTIVE_INTERVAL_MS = 2000
local IDLE_INTERVAL_MS = 8000
-- extend/mirror can try three ports (~6s each) and then restart Sunshine
-- (up to ~45s with retries); leave room so a slow but working start isn't
-- cut off.
local ACTION_TIMEOUT_MS = 90000
-- configure waits up to 10s for the script's lock (then exits 75, "busy") and
-- may restart Sunshine (~20s worst case); leave room for both.
local CONFIGURE_TIMEOUT_MS = 45000

local snapshot = { loading = true, mode = "off" }
local actionInFlight = "" -- "", or the action being run
local polling = false
local pollGen = 0
local lastConfig = ""
local configInFlight = false
local configPendingPoll = false
local configNeedsRetry = false
local configRetries = 0
local MAX_CONFIG_RETRIES = 5
local lastSerial = nil

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

local function ctlPath()
  return noctalia.pluginDir() .. "/bin/tablet-display-ctl"
end

local function shellQuote(s)
  return "'" .. string.gsub(tostring(s), "'", "'\\''") .. "'"
end

local function run(args, cb, timeoutMs)
  local argv = { "bash", ctlPath() }
  for _, a in ipairs(args) do
    table.insert(argv, a)
  end
  return noctalia.runAsync(argv, cb or function() end, timeoutMs or 20000)
end

local function publish()
  snapshot.pending = actionInFlight
  noctalia.state.set(STATE_KEY, snapshot)
  local active = snapshot.mode ~= nil and snapshot.mode ~= "off"
  noctalia.setUpdateInterval((active or actionInFlight ~= "") and ACTIVE_INTERVAL_MS or IDLE_INTERVAL_MS)
end

local function poll(force)
  if polling then
    if force then
      pollGen = pollGen + 1
    end
    return
  end
  polling = true
  local gen = pollGen
  -- While an action holds the script's lock, ask for state without the
  -- reconcile pass (it would only wait for the lock).
  local args = actionInFlight ~= "" and { "state", "--no-reconcile" } or { "state" }
  run(args, function(result)
    polling = false
    if gen ~= pollGen then
      poll(false)
      return
    end
    if result and result.exitCode == 0 then
      local ok, data = pcall(noctalia.json.decode, result.stdout or "")
      if ok and type(data) == "table" then
        data.available = true
        snapshot = data
        publish()
        return
      end
    end
    snapshot = {
      available = false,
      mode = "off",
      errors = { noctalia.string.trim((result and (result.stderr ~= "" and result.stderr or result.stdout)) or "state failed") },
    }
    publish()
  end, 15000)
end

local function configJson()
  return noctalia.json.encode({
    device = noctalia.getConfig("device"),
    customResolution = noctalia.getConfig("custom_resolution"),
    customDiagonal = noctalia.getConfig("custom_diagonal"),
    refreshRates = noctalia.getConfig("refresh_rates"),
    audio = noctalia.getConfig("audio") == true,
    method = noctalia.getConfig("method"),
    port = noctalia.getConfig("port"),
    keepSunshine = noctalia.getConfig("keep_sunshine") == true,
    usbKeepInternet = noctalia.getConfig("usb_keep_internet") ~= false,
  })
end

local function pushConfig(thenPoll)
  local json = configJson()
  if json == lastConfig then
    configNeedsRetry = false
    configRetries = 0
    if thenPoll then poll(true) end
    return
  end
  if configInFlight then
    if thenPoll then configPendingPoll = true end
    return
  end
  if actionInFlight ~= "" then
    -- Defer until the in-flight action releases the control script's lock.
    configNeedsRetry = true
    configRetries = 0
    return
  end
  configInFlight = true
  configNeedsRetry = false
  configPendingPoll = thenPoll == true
  run({ "configure", json }, function(result)
    configInFlight = false
    local shouldPoll = configPendingPoll
    configPendingPoll = false
    if result and not result.timedOut and result.exitCode == 0 then
      lastConfig = json
      configRetries = 0
      -- Re-check in case settings changed again while configure was running.
      if configJson() ~= lastConfig then
        pushConfig(shouldPoll)
        return
      end
    else
      local timedOut = not result or result.timedOut
      local busy = result and result.exitCode == 75
      if not busy then
        -- cmd_configure writes the settings before it restarts Sunshine, so a
        -- failed or timed-out run may have applied `json`. The script's state
        -- is unknown now: forget lastConfig so the next push (even of the old
        -- settings) is sent instead of being skipped as unchanged.
        lastConfig = ""
      end
      if timedOut or busy then
        if configRetries < MAX_CONFIG_RETRIES then
          configRetries = configRetries + 1
          configNeedsRetry = true
        end
        noctalia.log("configure " .. (timedOut and "timed out" or "busy") .. (configNeedsRetry and "; will retry" or "; giving up"))
      else
        noctalia.log("configure failed: " .. tostring(result and result.stderr))
        if configJson() ~= json then
          configRetries = 0
          pushConfig(shouldPoll)
          return
        end
      end
    end
    if shouldPoll then poll(true) end
  end, CONFIGURE_TIMEOUT_MS)
end

local LONG_ACTIONS = { extend = true, mirror = true, off = true, set = true }

local function runAction(command)
  local action = command.action
  if action == "refresh" then
    poll(true)
    return
  end

  if action == "doctor" then
    noctalia.runInTerminal("bash " .. shellQuote(ctlPath()) .. " doctor; echo; read -rp "
      .. shellQuote(tr("service.press_enter") .. " ") .. " _")
    return
  end

  if action == "install-helper" then
    local script = noctalia.pluginDir() .. "/helper/install.sh"
    noctalia.runInTerminal("echo " .. shellQuote(tr("service.installing_helper")) .. "; sudo bash "
      .. shellQuote(script) .. "; echo; read -rp " .. shellQuote(tr("service.press_enter") .. " ") .. " _")
    return
  end

  if action == "pair" or action == "admin" or action == "clear-errors" then
    run({ action }, function() poll(true) end)
    return
  end

  if not LONG_ACTIONS[action] then
    noctalia.log("unknown action: " .. tostring(action))
    return
  end
  if actionInFlight ~= "" then
    noctalia.notify(tr("title"), tr("service.busy", { action = actionInFlight }))
    return
  end

  local args = { action }
  if action == "set" then
    args = { "set", tostring(command.key or ""), tostring(command.value or "") }
  elseif action == "mirror" and type(command.target) == "string" and command.target ~= "" then
    args = { "mirror", command.target }
  end

  actionInFlight = action
  publish()
  run(args, function(result)
    actionInFlight = ""
    if not result or result.timedOut then
      noctalia.notifyError(tr("title"), tr("service.timed_out", { action = action }))
    elseif result.exitCode ~= 0 and result.exitCode ~= 75 then
      local msg = noctalia.string.trim(result.stderr or "")
      if msg == "" then
        msg = tr("service.failed", { action = action })
      end
      noctalia.notifyError(tr("title"), msg)
    end
    if configNeedsRetry or (not configInFlight and configJson() ~= lastConfig) then
      configRetries = 0
      pushConfig(true)
    else
      poll(true)
    end
  end, ACTION_TIMEOUT_MS)
end

noctalia.state.watch(COMMAND_KEY, function(command)
  if type(command) ~= "table" or type(command.action) ~= "string" then
    return
  end
  -- The watch can replay the last value; act on each request once.
  if command.serial ~= nil and command.serial == lastSerial then
    return
  end
  lastSerial = command.serial
  runAction(command)
end)

function update()
  if configNeedsRetry and not configInFlight and actionInFlight == "" then
    pushConfig(true)
    return
  end
  poll(false)
end

function onConfigChanged()
  configRetries = 0
  pushConfig(true)
end

function onResume()
  if configJson() ~= lastConfig then
    configRetries = 0
    pushConfig(true)
  else
    poll(true)
  end
end

function onIpc(event, _payload)
  if event == "extend" or event == "mirror" or event == "off" then
    runAction({ action = event })
  elseif event == "toggle" then
    runAction({ action = (snapshot.mode == "off" or snapshot.mode == nil) and "extend" or "off" })
  else
    poll(true)
  end
end

publish()
pushConfig(true)

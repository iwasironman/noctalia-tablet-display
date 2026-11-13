-- Minimal Hyprland session for testing the Tablet Display plugin.
-- Test by logging out of your usual session and choosing this one in the
-- greeter. Don't run it alongside another session on a second TTY: they share
-- your user systemd, and mango stops graphical-session.target when it exits,
-- which ends the other session too.
-- Copy to ~/.config/hypr/hyprland.lua (only if you have no Hyprland config).
-- Uses only what Noctalia's Hyprland page documents: hl.on, hl.exec_cmd,
-- hl.bind and hl.dsp.exec_cmd. Log out from Noctalia's session menu, or
-- SUPER+SHIFT+E.

hl.on("hyprland.start", function()
  -- Give the Sunshine service this session's display, not niri's.
  hl.exec_cmd("systemctl --user unset-environment NIRI_SOCKET SWAYSOCK")
  hl.exec_cmd("systemctl --user import-environment WAYLAND_DISPLAY HYPRLAND_INSTANCE_SIGNATURE XDG_CURRENT_DESKTOP")
  hl.exec_cmd("noctalia")
end)

local mainMod = "SUPER"
local ipc = "noctalia msg "
hl.bind(mainMod .. "+Return", hl.dsp.exec_cmd("ghostty"))
hl.bind(mainMod .. "+Space", hl.dsp.exec_cmd(ipc .. "panel-toggle launcher"))
hl.bind(mainMod .. "+S", hl.dsp.exec_cmd(ipc .. "panel-toggle control-center"))
hl.bind(mainMod .. "+Q", hl.dsp.exec_cmd("hyprctl dispatch killactive"))
hl.bind(mainMod .. "+SHIFT+E", hl.dsp.exec_cmd("hyprctl dispatch exit"))

#!/bin/bash
#
# nested-test.sh -- try the plugin's virtual-output back ends without logging
# into another session: starts Hyprland, sway or mango as a window inside the
# current session, then opens a shell wired to it.
#
#   test/nested-test.sh hyprland | sway | mango
#
# In that shell, `ctl` is tablet-display-ctl pointed at the nested compositor,
# with its own state and Sunshine started directly (not through the systemd
# unit). Moonlight connects as usual; pairing is shared. Leaving the shell
# turns the display off and closes the nested compositor.
#
# Isolation: the nested compositor gets a private XDG_RUNTIME_DIR and no
# D-Bus session bus. Without that, compositors that manage systemd user
# targets (mango stops graphical-session.target when it exits) would shut
# down the session you are running this from.
#
# Limits: Moonlight's mouse and keyboard reach the outer session, not the
# nested one (the outer compositor owns the input devices Sunshine creates),
# so this checks the picture, sizing and placement, not input.

set -euo pipefail

COMP=${1:-}
HERE=$(dirname "$(realpath "$0")")
CTL=$(realpath "$HERE/../tablet-display/bin/tablet-display-ctl")
OUTER_RT=${XDG_RUNTIME_DIR:?}
WORK="$OUTER_RT/tablet-display-nested-$COMP"
RT="$WORK/rt"   # the nested compositor's private runtime dir

die() { echo "nested-test: $*" >&2; exit 1; }

case $COMP in
  hyprland) BIN=Hyprland ;;
  sway) BIN=sway ;;
  mango) BIN=mango ;;
  *) sed -n '3,16p' "$0"; exit 64 ;;
esac
command -v "$BIN" >/dev/null || die "$BIN is not installed"
[[ -n ${WAYLAND_DISPLAY:-} ]] || die "run this from inside a Wayland session"

# The real plugin and Sunshine must be idle: the test starts its own Sunshine
# and stopping it kills any other.
if systemctl --user is-active --quiet app-dev.lizardbyte.app.Sunshine.service; then
  die "Sunshine is running. Turn the tablet display off in the panel, then: systemctl --user stop app-dev.lizardbyte.app.Sunshine"
fi
pgrep -x sunshine >/dev/null && die "a sunshine process is running; stop it first"

rm -rf "$WORK"; mkdir -p "$WORK" "$RT"; chmod 700 "$RT"
# Connect to the outer compositor by absolute path, since XDG_RUNTIME_DIR
# changes below.
OUTER_WAYLAND="$OUTER_RT/$WAYLAND_DISPLAY"
[[ $WAYLAND_DISPLAY == /* ]] && OUTER_WAYLAND=$WAYLAND_DISPLAY
ISOLATE=(env -u DBUS_SESSION_BUS_ADDRESS -u NIRI_SOCKET -u SWAYSOCK -u HYPRLAND_INSTANCE_SIGNATURE
  -u MANGO_INSTANCE_SIGNATURE XDG_RUNTIME_DIR="$RT" WAYLAND_DISPLAY="$OUTER_WAYLAND")
: >"$WORK/empty.conf"
: >"$WORK/empty.lua"

sockets() { ls "$RT" 2>/dev/null | grep -E '^wayland-[0-9]+$' | sort; }
before=$(sockets)
hypr_before=$(ls "$RT/hypr" 2>/dev/null | sort || true)

echo "Starting nested $BIN…"
case $COMP in
  hyprland) "${ISOLATE[@]}" "$BIN" --config "$WORK/empty.lua" >"$WORK/compositor.log" 2>&1 & ;;
  sway) "${ISOLATE[@]}" "$BIN" -c "$WORK/empty.conf" >"$WORK/compositor.log" 2>&1 & ;;
  mango) "${ISOLATE[@]}" "$BIN" -c "$WORK/empty.conf" >"$WORK/compositor.log" 2>&1 & ;;
esac
PID=$!

nested=""
for _ in {1..100}; do
  nested=$(comm -13 <(printf '%s\n' "$before") <(sockets) | head -1)
  [[ -n $nested ]] && break
  kill -0 "$PID" 2>/dev/null || { cat "$WORK/compositor.log" >&2; die "$BIN exited"; }
  sleep 0.1
done
[[ -n $nested ]] || { kill "$PID"; die "no new Wayland socket appeared"; }

ENV=(env -u NIRI_SOCKET -u HYPRLAND_INSTANCE_SIGNATURE -u SWAYSOCK -u MANGO_INSTANCE_SIGNATURE
  -u DBUS_SESSION_BUS_ADDRESS
  XDG_RUNTIME_DIR="$RT"
  WAYLAND_DISPLAY="$nested"
  TABLET_DISPLAY_STATE_DIR="$WORK/state"
  TABLET_DISPLAY_RUN_DIR="$WORK/run"
  TABLET_DISPLAY_SUNSHINE_UNIT=none)
case $COMP in
  hyprland)
    sig=""
    for _ in {1..50}; do
      sig=$(comm -13 <(printf '%s\n' "$hypr_before") <(ls "$RT/hypr" 2>/dev/null | sort) | head -1)
      [[ -n $sig ]] && break; sleep 0.1
    done
    [[ -n $sig ]] || die "could not find the nested Hyprland instance"
    ENV+=(HYPRLAND_INSTANCE_SIGNATURE="$sig" XDG_CURRENT_DESKTOP=Hyprland) ;;
  sway)
    sock=""
    for _ in {1..50}; do
      sock=$(ls "$RT"/sway-ipc.*."$PID".sock 2>/dev/null | head -1)
      [[ -n $sock ]] && break; sleep 0.1
    done
    [[ -n $sock ]] || die "could not find the nested sway IPC socket"
    ENV+=(SWAYSOCK="$sock" XDG_CURRENT_DESKTOP=sway) ;;
  mango)
    msock=""
    for _ in {1..50}; do
      msock=$(ls "$RT"/mango-*.sock 2>/dev/null | head -1)
      [[ -n $msock ]] && break; sleep 0.1
    done
    [[ -n $msock ]] || die "could not find the nested mango socket"
    ENV+=(MANGO_INSTANCE_SIGNATURE="$msock" XDG_CURRENT_DESKTOP=mango) ;;
esac

cleanup() {
  echo "Turning off and closing nested $BIN…"
  "${ENV[@]}" bash "$CTL" off >/dev/null 2>&1 || true
  kill "$PID" 2>/dev/null || true
}
trap cleanup EXIT

"${ENV[@]}" bash "$CTL" configure '{"device":"galaxy-tab-s9-ultra","refreshRates":"60,90,120"}'

cat >"$WORK/rc" <<RC
[ -f ~/.bashrc ] && . ~/.bashrc
ctl() { bash '$CTL' "\$@"; }
PS1='[td-test $COMP] \w \$ '
cat <<'HELP'

Nested $BIN is running on $nested. Try:
  ctl extend                      add the tablet display, start Sunshine
  ctl state | jq .                what the plugin sees
  ctl set position left|right|above|below
  ctl set scale 1.5
  ctl doctor
  ctl off
Then connect Moonlight to this computer as usual. Type exit to finish.
Logs: $WORK/run/ctl.log  $WORK/compositor.log
HELP
RC

"${ENV[@]}" bash --rcfile "$WORK/rc" -i

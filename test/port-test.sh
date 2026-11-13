#!/bin/bash
#
# port-test.sh -- turn an unused DRM connector into a "virtual" monitor by
# loading an EDID override onto it and forcing it connected.
#
#   ./port-test.sh list                       # no root needed
#   sudo ./port-test.sh on  card2-DP-3 [edid.bin]
#   sudo ./port-test.sh off card2-DP-3
#   sudo ./port-test.sh poke card2-DP-3      # resend only the hotplug event
#
# Everything is runtime-only: a reboot undoes it.

set -euo pipefail

HERE=$(dirname "$(realpath "$0")")
DEFAULT_EDID="$HERE/tablet-s9u.bin"
DEBUGFS=/sys/kernel/debug

die() { echo "port-test: $*" >&2; exit 1; }

need_root() { [[ $EUID -eq 0 ]] || die "run this with sudo"; }

conn_path() {
  local c=$1
  [[ $c =~ ^card[0-9]+-[A-Za-z]+(-[A-Za-z]+)?-[0-9]+$ ]] || die "bad connector name '$c' (expected e.g. card2-DP-3)"
  [[ -d /sys/class/drm/$c ]] || die "no such connector: $c"
  echo "/sys/class/drm/$c"
}

# debugfs groups connectors per GPU; match that GPU by PCI address through
# each dri/N/name file ("amdgpu dev=0000:c5:00.0 unique=...").
debugfs_conn_dir() {
  local c=$1 card=${1%%-*} name=${1#*-} pci d
  pci=$(basename "$(readlink -f "/sys/class/drm/$card/device")")
  mountpoint -q "$DEBUGFS" || mount -t debugfs none "$DEBUGFS" || die "cannot mount debugfs"
  for d in "$DEBUGFS"/dri/*/; do
    [[ -f $d/name ]] && grep -q "dev=$pci" "$d/name" && [[ -d $d$name ]] && { echo "$d$name"; return; }
  done
  die "no debugfs directory for $c (GPU $pci). Is the kernel locked down? $(cat /sys/kernel/security/lockdown 2>/dev/null)"
}

# Writing a connector's sysfs status re-probes it but sends no uevent, so
# compositors never hear about it. Send a synthetic one, with HOTPLUG=1 as
# real hotplugs carry (wlroots ignores change events without it).
hotplug() {
  local card=${1%%-*} uuid
  uuid=$(cat /proc/sys/kernel/random/uuid)
  echo "sending hotplug event for $card"
  echo "change $uuid HOTPLUG=1" >"/sys/class/drm/$card/uevent"
}

cmd_list() {
  local c
  printf '%-16s %-13s %s\n' CONNECTOR STATUS NOTE
  for c in /sys/class/drm/card*-*; do
    c=${c##*/}
    [[ $c == *Writeback* ]] && continue
    local st note=""
    st=$(cat "/sys/class/drm/$c/status")
    [[ $st == connected ]] && note="real monitor attached"
    [[ $st == disconnected ]] && note="free"
    [[ $c == *eDP* ]] && note="internal panel connector, do not use"
    printf '%-16s %-13s %s\n' "$c" "$st" "$note"
  done
}

cmd_on() {
  need_root
  local c=$1 edid=${2:-$DEFAULT_EDID} sys dbg
  sys=$(conn_path "$c")
  [[ $c == *eDP* ]] && die "refusing to touch the internal panel"
  [[ -f $edid ]] || die "EDID file not found: $edid (run make-edid.py first)"
  [[ $(cat "$sys/status") == disconnected ]] || die "$c is not disconnected; pick a free port"
  dbg=$(debugfs_conn_dir "$c")

  local mark
  mark=$(date '+%F %T')
  echo "loading $(stat -c %s "$edid")-byte EDID onto $c"
  cat "$edid" >"$dbg/edid_override"
  echo "forcing $c on"
  echo on >"$sys/status"
  hotplug "$c"
  sleep 2

  echo
  echo "status:  $(cat "$sys/status")"
  echo "enabled: $(cat "$sys/enabled")"
  echo "modes:   $(tr '\n' ' ' <"$sys/modes")"
  echo
  echo "kernel messages since $mark:"
  journalctl -k --since "$mark" --no-pager -q | tail -20 || true
  echo
  echo "Now check niri:  niri msg outputs"
}

cmd_off() {
  need_root
  local c=$1 sys dbg
  sys=$(conn_path "$c")
  [[ $c == *eDP* ]] && die "refusing to touch the internal panel"
  dbg=$(debugfs_conn_dir "$c")
  echo "forcing $c off"
  echo off >"$sys/status"
  hotplug "$c"
  sleep 1
  echo "clearing EDID override"
  # Exactly "reset": with echo's newline the kernel reads it as a 6-byte EDID.
  printf reset >"$dbg/edid_override"
  echo "returning $c to normal hotplug detection"
  echo detect >"$sys/status"
  # amdgpu keeps the emulated sink attached across a re-detect; its
  # trigger_hotplug file simulates the unplug.
  if [[ $(cat "$sys/status") == connected && -e $dbg/trigger_hotplug ]]; then
    echo "simulating unplug (amdgpu)"
    echo 0 >"$dbg/trigger_hotplug"
  fi
  hotplug "$c"
  sleep 0.2
  echo "status: $(cat "$sys/status")"
}

case "${1:-}" in
  list) cmd_list ;;
  poke) [[ $# -ge 2 ]] || die "usage: sudo $0 poke <connector>"; need_root; conn_path "$2" >/dev/null; hotplug "$2" ;;
  on)   [[ $# -ge 2 ]] || die "usage: sudo $0 on <connector> [edid.bin]"; cmd_on "$2" "${3:-}" ;;
  off)  [[ $# -ge 2 ]] || die "usage: sudo $0 off <connector>"; cmd_off "$2" ;;
  *)    sed -n '3,11p' "$0"; exit 64 ;;
esac

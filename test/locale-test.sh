#!/bin/bash
#
# locale-test.sh -- checks that tablet-display-ctl formats numbers with '.'
# under a comma-decimal locale, and hands the user's own locale back to the
# programs it starts (user_locale).
#
#   ./locale-test.sh            # no root, touches nothing outside a temp dir
#
# The decimal checks are skipped when no comma-decimal locale is installed.

set -uo pipefail

HERE=$(dirname "$(realpath "$0")")
CTL="$HERE/../tablet-display/bin/tablet-display-ctl"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# The script's functions without its command dispatch at the bottom.
sed '/^case "\${1:-}" in$/,$d' "$CTL" >"$TMP/lib.sh"

fails=0
check() { # name expected actual
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'"; fails=$((fails + 1)); fi
}

# Runs a snippet with the script sourced, in a clean environment plus "$@".
run() { # snippet VAR=value...
  local snippet=$1; shift
  env -i PATH="$PATH" HOME="$TMP" \
    TABLET_DISPLAY_STATE_DIR="$TMP/state" TABLET_DISPLAY_RUN_DIR="$TMP/run" "$@" \
    bash -c 'source "$1" 2>/dev/null; eval "$2"' _ "$TMP/lib.sh" "$snippet" 2>/dev/null
}

comma=$(locale -a 2>/dev/null | grep -iE '^(de_DE|fr_FR|es_ES|it_IT|nl_NL|pt_BR|ru_RU)\.utf-?8$' | head -1)
if [[ -n $comma && $(LC_ALL=$comma locale decimal_point 2>/dev/null) == "," ]]; then
  for env in "LC_ALL=$comma" "LANG=$comma" "LC_NUMERIC=$comma"; do
    check "printf under $env" "59.951" "$(run 'printf "%.3f" 59.951' "$env")"
    check "auto_scale under $env" "2" "$(run 'auto_scale 2960 1848 14.6' "$env")"
    check "flock -w 0.3 under $env" "0" "$(run ': >"$HOME/l"; exec 9>"$HOME/l"; flock -w 0.3 9; echo $?' "$env")"
  done
else
  echo "skip decimal checks: no comma-decimal locale installed"
fi

# What a program started through user_locale sees, as "VAR=value ..." for the
# variables that are set.
show='for v in LC_ALL LANG LC_MESSAGES LC_NUMERIC TABLET_DISPLAY_USER_LOCALE; do [[ -n ${!v+x} ]] && printf "%s " "$v=${!v}"; done'
check "user_locale restores LC_ALL and masked vars" \
  "LC_ALL=en_US.UTF-8 LANG=fr_FR.UTF-8 LC_MESSAGES=de_DE.UTF-8 " \
  "$(run "user_locale bash -c '$show'" LC_ALL=en_US.UTF-8 LANG=fr_FR.UTF-8 LC_MESSAGES=de_DE.UTF-8)"
check "LC_ALL spread keeps LC_MESSAGES" "en_US.UTF-8" \
  "$(run 'echo "$LC_MESSAGES"' LC_ALL=en_US.UTF-8 LC_MESSAGES=de_DE.UTF-8)"
check "user_locale restores LC_NUMERIC" "LANG=en_US.UTF-8 LC_NUMERIC=de_DE.UTF-8 " \
  "$(run "user_locale bash -c '$show'" LANG=en_US.UTF-8 LC_NUMERIC=de_DE.UTF-8)"
check "re-run script passes the original on" "LANG=en_US.UTF-8 LC_NUMERIC=de_DE.UTF-8 " \
  "$(run "bash -c 'source \"\$0\" 2>/dev/null; user_locale bash -c \"\$1\"' \"$TMP/lib.sh\" '$show'" LANG=en_US.UTF-8 LC_NUMERIC=de_DE.UTF-8)"

((fails == 0)) && echo "all passed" || { echo "$fails failed"; exit 1; }

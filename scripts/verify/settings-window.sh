#!/usr/bin/env bash
# Usage: scripts/verify/settings-window.sh
# D-01 / D-25 / SET-02: every way into Settings opens the one Settings window, and Metr shows its Dock
# icon and main menu (the regular activation policy) exactly while any Metr window is open.
#
# Three scripted runs of the Debug app (always with -MetrDidPresentWelcome YES; a scripted run keeps
# the Refresh speed in a separate suite that this script deletes, so the owner's preferences domain
# is never written):
#   a. settings@1;settings@3;settings-close@6      two opens give `settings shown count=1` twice, never
#                                                  count=2, and the close returns Metr to accessory;
#   b. last@1;settings@3;close@5;settings-close@8  closing the main window under Settings logs
#                                                  `window closed policy=regular`, Settings stays and
#                                                  only its own close logs accessory; the main menu holds
#                                                  one Settings, one Close, one Metr and six sections;
#   c. settings@1;last@3;settings-close@5;close@8  closing Settings first keeps the main window regular
#                                                  (`settings closed policy=regular`), and the last
#                                                  close logs `window closed policy=accessory`.
# Also checks, statically, that the Settings Form holds no control beyond the minimal set (D-02).
# Prints "SETTINGS-WINDOW OK" or "FAIL: <what>" with exit 1.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
# shellcheck source=../env.sh
source scripts/env.sh

SCRIPT_SUITE="io.github.latarocaballero.Metr.script"
OWNER_DOMAIN="$(metr_bundle_id)"

cleanup() {
  metr_kill >/dev/null 2>&1 || true
  defaults delete "$SCRIPT_SUITE" >/dev/null 2>&1 || true
}
trap cleanup EXIT

fail() { echo "FAIL: $1"; exit 1; }

[ -d "$METR_APP_DEBUG" ] || fail "Debug app not found at $METR_APP_DEBUG (run scripts/build.sh debug)"

# Line number of the first line matching a regex, or empty.
first_line() { grep -nE -- "$2" "$1" | head -n 1 | cut -d: -f1 || true; }

run() {
  # run NAME SECONDS SCRIPT [run-debug options...]
  local name="$1" secs="$2" script="$3"
  shift 3
  local out
  if ! out="$(bash scripts/verify/run-debug.sh "$secs" "$name" \
      --env "METR_DEBUG_WINDOW_SCRIPT=$script" "$@" \
      --reject 'count=[2-9]' --reject 'FATAL' \
      --args -MetrDidPresentWelcome YES 2>&1)"; then
    echo "$out" | grep -E '^FAIL' || echo "$out"
    exit 1
  fi
}

# a. two opens, one window
run settings-window-a 9 'settings@1;settings@3;settings-close@6' \
  --expect 'settings shown count=1 key=[01] policy=regular' --min 2 --max 2 \
  --expect 'settings closed policy=accessory' --min 1 --max 1
LOG_A="$METR_LOGS/settings-window-a.log"
[ "$(grep -c 'panel close requested' "$LOG_A")" -ge 1 ] || fail "opening Settings did not close the panel first (LOG=$LOG_A)"

# b. main window, then Settings; the main window closes first
run settings-window-b 11 'last@1;settings@3;close@5;settings-close@8' \
  --expect 'menu settings=1 close=1 metr=1 sections=6' --min 1 \
  --expect 'window closed policy=regular' --min 1 --max 1 \
  --expect 'settings closed policy=accessory' --min 1 --max 1 \
  --reject 'window closed policy=accessory' \
  --reject 'settings closed policy=regular'
LOG_B="$METR_LOGS/settings-window-b.log"
main_line="$(first_line "$LOG_B" 'window closed policy=regular')"
settings_line="$(first_line "$LOG_B" 'settings closed policy=accessory')"
[ -n "$main_line" ] && [ -n "$settings_line" ] && [ "$main_line" -lt "$settings_line" ] \
  || fail "the main window's close did not come before Settings' (LOG=$LOG_B)"

# c. Settings first, then the main window closes last
run settings-window-c 11 'settings@1;last@3;settings-close@5;close@8' \
  --expect 'settings closed policy=regular' --min 1 --max 1 \
  --expect 'window closed policy=accessory' --min 1 --max 1 \
  --reject 'settings closed policy=accessory' \
  --reject 'window closed policy=regular'
LOG_C="$METR_LOGS/settings-window-c.log"
settings_line="$(first_line "$LOG_C" 'settings closed policy=regular')"
main_line="$(first_line "$LOG_C" 'window closed policy=accessory')"
[ -n "$main_line" ] && [ -n "$settings_line" ] && [ "$settings_line" -lt "$main_line" ] \
  || fail "Settings' close did not come before the main window's (LOG=$LOG_C)"

# D-02: the Settings Form holds the minimal set and nothing else.
VIEW="Metr/Settings/SettingsView.swift"
pickers="$(grep -c 'Picker(' "$VIEW" || true)"
[ "$pickers" -eq 1 ] || fail "$VIEW holds $pickers pop-ups; Refresh speed is the only one (D-02)"
if grep -qE 'TabView|Slider\(|Stepper\(|TextField\(|SecureField\(|NavigationLink|\.tabItem' "$VIEW"; then
  fail "$VIEW holds a control Settings never has (D-02)"
fi

# Scripted runs never write the owner's preferences or leave the script suite behind.
cleanup
if defaults read "$OWNER_DOMAIN" >/dev/null 2>&1; then fail "the owner's preferences domain $OWNER_DOMAIN exists"; fi
if defaults read "$SCRIPT_SUITE" >/dev/null 2>&1; then fail "the script suite $SCRIPT_SUITE still exists"; fi

echo "SETTINGS-WINDOW OK"

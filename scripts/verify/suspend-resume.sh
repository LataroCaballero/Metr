#!/usr/bin/env bash
# HUMAN-RUN: turns the display off for about 20 s. Never run unattended or in automated verify.
# Launches the Debug app, sleeps the display, wakes it, then asserts on the DEBUG log:
#   suspend reason=displaySleep -> resume reason=displaySleep -> prime,
# with no "tick dt=" line between the suspend and the resume.
# Prints "SUSPEND-RESUME OK" or "FAIL: <why>" with exit 1.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
# shellcheck source=../env.sh
source scripts/env.sh

fail() { echo "FAIL: $1"; exit 1; }

[ -d "$METR_APP_DEBUG" ] || fail "Debug app not found at $METR_APP_DEBUG (run scripts/build.sh debug)"

mkdir -p "$METR_LOGS"
LOG="$METR_LOGS/suspend.log"
: > "$LOG"

metr_kill
open -g -n --env "METR_DEBUG_LOG=$LOG" "$METR_APP_DEBUG"
sleep 6
pmset displaysleepnow
sleep 20
caffeinate -u -t 2
sleep 6
metr_kill

suspend_line="$(grep -n 'suspend reason=displaySleep' "$LOG" | head -n 1 | cut -d: -f1 || true)"
[ -n "$suspend_line" ] || fail "no 'suspend reason=displaySleep' line (LOG=$LOG)"

resume_line="$(awk -v s="$suspend_line" 'NR > s && /resume reason=displaySleep/ { print NR; exit }' "$LOG")"
[ -n "$resume_line" ] || fail "no 'resume reason=displaySleep' after the suspend (LOG=$LOG)"

between="$(awk -v s="$suspend_line" -v r="$resume_line" 'NR > s && NR < r && /tick dt=/ { n++ } END { print n + 0 }' "$LOG")"
[ "$between" = "0" ] || fail "$between tick line(s) between suspend and resume (LOG=$LOG)"

awk -v r="$resume_line" 'NR > r && / prime$/ { found = 1 } END { exit found ? 0 : 1 }' "$LOG" \
  || fail "no 'prime' line after the resume (LOG=$LOG)"

echo "LOG=$LOG"
echo "SUSPEND-RESUME OK"

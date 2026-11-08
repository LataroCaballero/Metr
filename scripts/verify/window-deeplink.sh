#!/usr/bin/env bash
# Usage: scripts/verify/window-deeplink.sh
# D-01 / PANEL-06: the panel's "and N more..." link opens the window on Processes with that app's
# group expanded, selected and scrolled into view, and the process list stays alive across the
# handoff (RESEARCH Pitfall 1: the window's process demand is registered before the panel closes).
#
# Picks the current user's outermost .app bundle that has the most running processes (at least 2),
# runs the Debug app for 10 s with METR_DEBUG_WINDOW_SCRIPT=processes:<bundle>@1;close@9 through
# run-debug.sh (the same entry point the link uses), and requires:
#   - `window shown section=processes`;
#   - `table focus found=1 expanded=1 selected=1 inview=1` (the line also says fallback=<0|1>:
#     whether the table's own scrollRowToVisible had to finish the scroll, RESEARCH assumption A5);
#   - the first `window demand=window,windowProcesses` line comes BEFORE the first
#     `panel close requested` line, and no `procs pending` line sits between them.
# Prints "WINDOW-DEEPLINK OK bundle-processes=<n> fallback=<0|1>" (never the bundle's path), or
# "FAIL: <what>" with exit 1. Always launches with -MetrDidPresentWelcome YES so the owner's
# preferences stay untouched.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
# shellcheck source=../env.sh
source scripts/env.sh

fail() { echo "FAIL: $1"; exit 1; }

[ -d "$METR_APP_DEBUG" ] || fail "Debug app not found at $METR_APP_DEBUG (run scripts/build.sh debug)"

ME="$(id -u)"
# "<count>\t<bundle path>" of the busiest own-uid outermost .app bundle.
BEST="$(
  ps -axo uid=,comm= \
    | awk -v me="$ME" '
        $1 == me {
          line = $0
          sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", line)
          i = index(line, ".app/")
          if (i == 0) next
          bundle = substr(line, 1, i + 3)
          count[bundle]++
        }
        END { for (b in count) printf "%d\t%s\n", count[b], b }' \
    | sort -rn \
    | head -n 1
)"
[ -n "$BEST" ] || fail "no multi-process app running"
COUNT="${BEST%%$'\t'*}"
BUNDLE="${BEST#*$'\t'}"
[ "$COUNT" -ge 2 ] || fail "no multi-process app running"

# run-debug.sh's own messages name the expectation and the log, never the bundle.
if ! RUN_OUT="$(bash scripts/verify/run-debug.sh 10 window-deeplink \
  --env "METR_DEBUG_WINDOW_SCRIPT=processes:${BUNDLE}@1;close@9" \
  --expect 'window shown section=processes' \
  --expect 'table focus found=1 expanded=1 selected=1 inview=1' \
  --args -MetrDidPresentWelcome YES 2>&1)"; then
  echo "$RUN_OUT" | grep -E '^FAIL' || true
  exit 1
fi

LOG="$METR_LOGS/window-deeplink.log"

demand_line="$(grep -n 'window demand=window,windowProcesses' "$LOG" | head -n 1 | cut -d: -f1 || true)"
close_line="$(grep -n 'panel close requested' "$LOG" | head -n 1 | cut -d: -f1 || true)"
[ -n "$demand_line" ] || fail "no 'window demand=window,windowProcesses' line (LOG=$LOG)"
[ -n "$close_line" ] || fail "no 'panel close requested' line (LOG=$LOG)"
[ "$demand_line" -lt "$close_line" ] \
  || fail "the panel closed (line $close_line) before the window's process demand (line $demand_line) (LOG=$LOG)"
if sed -n "${demand_line},${close_line}p" "$LOG" | grep -q 'procs pending'; then
  fail "the process list reset between the demand and the panel close (LOG=$LOG)"
fi

fallback="$(grep -E 'table focus found=1 expanded=1 selected=1 inview=1' "$LOG" | head -n 1 \
  | sed -nE 's/.*fallback=([01]).*/\1/p')"
fallback="${fallback:-0}"

echo "WINDOW-DEEPLINK OK bundle-processes=$COUNT fallback=$fallback"

#!/usr/bin/env bash
# Usage: scripts/spikes/app-nap.sh --minutes N
# ROADMAP Phase 1 spike for Phase 4 (RESEARCH A9): does App Nap stretch the 2 s idle timer of an
# LSUIElement app that is not frontmost? Launches the Debug app in the background (open -g), leaves
# it alone for N minutes, then summarises the "tick dt=" intervals of the idle tier.
#
# Prints "APP-NAP power=<AC|Battery> median=<v> p95=<v> max=<v> n=<n> verdict=<THROTTLED|NOT-THROTTLED>"
# and "APP-NAP DONE". THROTTLED means the 95th percentile of the tick interval is above 3.0 s.
# Use other apps normally while it runs, and run it once on AC power and once on battery.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
# shellcheck source=../env.sh
source scripts/env.sh

fail() { echo "FAIL: $1"; exit 1; }

[ "${1:-}" = "--minutes" ] && [ -n "${2:-}" ] || { echo "usage: app-nap.sh --minutes N" >&2; exit 2; }
MINUTES="$2"
case "$MINUTES" in ''|*[!0-9.]*) echo "usage: app-nap.sh --minutes N" >&2; exit 2 ;; esac

case "$(pmset -g batt | head -n 1)" in
  *"AC Power"*) POWER="AC" ;;
  *"Battery Power"*) POWER="Battery" ;;
  *) POWER="Unknown" ;;
esac

[ -d "$METR_APP_DEBUG" ] || fail "Debug app not found at $METR_APP_DEBUG (run scripts/build.sh debug)"

mkdir -p "$METR_LOGS"
LOG="$METR_LOGS/app-nap.log"
: > "$LOG"

metr_kill
trap 'metr_kill || true' EXIT
open -g -n --env "METR_DEBUG_LOG=$LOG" "$METR_APP_DEBUG" --args -MetrDidPresentWelcome YES

sleep "$(awk -v m="$MINUTES" 'BEGIN { printf "%d", m * 60 }')"
metr_kill

# Skip the first two lines (the baseline tick and the priming tick).
values="$(grep -E 'tick dt=' "$LOG" | sed -E 's/.*tick dt=([0-9.]+).*/\1/' | tail -n +3)"
n="$(printf '%s\n' "$values" | grep -c . || true)"
[ "$n" -ge 3 ] || fail "need at least 3 tick intervals after the first two, found $n (log: $LOG)"

stats="$(printf '%s\n' "$values" | sort -n | awk '
  { a[NR] = $1 }
  END {
    if (NR % 2) med = a[(NR + 1) / 2]; else med = (a[NR / 2] + a[NR / 2 + 1]) / 2
    idx = int(0.95 * NR); if (idx < 1) idx = 1; if (idx < 0.95 * NR) idx++
    if (idx > NR) idx = NR
    printf "%.3f %.3f %.3f", med, a[idx], a[NR]
  }')"
median="${stats%% *}"
rest="${stats#* }"
p95="${rest%% *}"
max="${rest#* }"
verdict="NOT-THROTTLED"
[ "$(awk -v p="$p95" 'BEGIN { print (p > 3.0) ? 1 : 0 }')" = "0" ] || verdict="THROTTLED"

echo "APP-NAP power=$POWER median=$median p95=$p95 max=$max n=$n verdict=$verdict"
echo "APP-NAP DONE"

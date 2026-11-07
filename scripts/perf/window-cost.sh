#!/usr/bin/env bash
# Usage: scripts/perf/window-cost.sh SECTION [SECONDS]
# Cost of the open Metr window per sidebar section (D-05, WIN-01). SECTION is one of
# cpu memory disk network gpu processes; SECONDS defaults to 20.
#
# Launches the Debug app with the window script opening SECTION (METR_DEBUG_WINDOW_SCRIPT) and the
# welcome window suppressed, waits 5 s, then checks the top child and measures Metr's own process
# with proc_pid_rusage (scripts/perf/rusage.swift) over SECONDS. Debug build, so this is an upper
# bound, and top's cost is panel-cost.sh's business, not this script's.
#   - a metric section must have NO top child; Processes must have one (the process pass);
#   - Metr's CPU must stay under WINDOW_CPU_PCT_MAX (metric sections) or
#     WINDOW_PROCESSES_CPU_PCT_MAX (processes), both from scripts/perf/budget.env;
#   - quitting Metr must take the top child with it (NO-ORPHAN OK within 3 s).
#
# Prints
#   WINDOW-COST section=<s> metr_cpu=<v> top=<0|1>
#   NO-ORPHAN OK (only when a top child existed; otherwise NO-ORPHAN OK means none was left)
# or "FAIL: <reason>" with exit 1. Every number is validated as a plain number (fail closed).
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
# shellcheck source=../env.sh
source scripts/env.sh
# shellcheck source=lib.sh
source scripts/perf/lib.sh
# shellcheck source=budget.env
source scripts/perf/budget.env

SECTION="${1:-}"
SECS="${2:-20}"
case "$SECTION" in
  cpu|memory|disk|network|gpu|processes) ;;
  *) echo "usage: window-cost.sh SECTION [SECONDS]  (SECTION: cpu memory disk network gpu processes)" >&2; exit 2 ;;
esac
case "$SECS" in
  ''|*[!0-9.]*) echo "usage: window-cost.sh SECTION [SECONDS]" >&2; exit 2 ;;
esac

fail() { echo "$1"; exit 1; }

[ -d "$METR_APP_DEBUG" ] || fail "FAIL: Debug app not found at $METR_APP_DEBUG (run scripts/build.sh debug)"

if [ "$SECTION" = "processes" ]; then
  BUDGET="${WINDOW_PROCESSES_CPU_PCT_MAX:-}"
else
  BUDGET="${WINDOW_CPU_PCT_MAX:-}"
fi
metr_is_number "$BUDGET" || fail "FAIL: window budget for $SECTION is not a plain number in budget.env ('$BUDGET')"

RUSAGE_BIN="$(metr_rusage_bin)"   # build it before the window, so compiling is not measured
mkdir -p "$METR_LOGS"
LOG="$METR_LOGS/window-cost-$SECTION.log"
rm -f "$LOG"

metr_kill
trap 'metr_kill || true' EXIT

open -g -n --env "METR_DEBUG_LOG=$LOG" --env "METR_DEBUG_WINDOW_SCRIPT=$SECTION@0.5" "$METR_APP_DEBUG" \
  --args -MetrDidPresentWelcome YES
sleep 5

PID="$(metr_pid "$METR_APP_DEBUG")"
[ -n "$PID" ] || fail "FAIL: Metr did not start"
TOP_PID="$(pgrep -P "$PID" -x top | head -n 1 || true)"
if [ "$SECTION" = "processes" ]; then
  [ -n "$TOP_PID" ] || fail "FAIL: no top child with processes selected"
  TOP=1
else
  [ -z "$TOP_PID" ] || fail "FAIL: top child running with $SECTION selected (pid $TOP_PID)"
  TOP=0
fi
echo "MEASURING pid=$PID section=$SECTION top=$TOP window=${SECS}s"

LINE="$("$RUSAGE_BIN" "$PID" "$SECS")" || fail "FAIL: proc_pid_rusage failed for pid $PID"
echo "$LINE"
METR_CPU="$(printf '%s\n' "$LINE" | sed -E 's/.*cpu_pct=([0-9.]+).*/\1/')"
metr_is_number "$METR_CPU" || fail "FAIL: could not parse a number (value '$METR_CPU', line: $LINE)"

# The top child must still agree with the section after the measuring window (no late start).
if [ "$SECTION" != "processes" ]; then
  LATE="$(pgrep -P "$PID" -x top | head -n 1 || true)"
  [ -z "$LATE" ] || fail "FAIL: top child appeared with $SECTION selected (pid $LATE)"
fi

echo "WINDOW-COST section=$SECTION metr_cpu=$METR_CPU top=$TOP"
[ "$(metr_gt "$METR_CPU" "$BUDGET")" = "0" ] || fail "FAIL: window cpu $METR_CPU above $BUDGET"

# Quit Metr: a top child must go with it.
metr_kill
if [ -z "$TOP_PID" ]; then
  echo "NO-ORPHAN OK"
  exit 0
fi
for _ in $(seq 1 30); do
  kill -0 "$TOP_PID" 2>/dev/null || { echo "NO-ORPHAN OK"; exit 0; }
  sleep 0.1
done
fail "FAIL: orphaned top (pid $TOP_PID still running 3 s after Metr exited)"

#!/usr/bin/env bash
# Usage: scripts/perf/panel-cost.sh [SECONDS]
# Panel-open cost of the Debug app and of its streamed top child (owner decision Q1,
# RESEARCH A9), plus the process-list warm-up time. SECONDS defaults to 30.
#
# Launches the Debug app with the panel tier forced on (METR_DEBUG_DEMAND=panel) and the welcome
# window suppressed, waits 5 s, finds Metr's top child, then measures both over SECONDS:
#   - Metr: proc_pid_rusage (scripts/perf/rusage.swift). Debug build, so this is an upper bound.
#   - top: the growth of its cumulative CPU time from `ps -o time=` (rusage cannot read a root
#     process), divided by the window.
# The warm-up is read from the app's debug log: the uptime of the first `procs n=` line with
# ready=1 minus the uptime of the first `procs n=` line.
#
# Prints
#   PANEL-COST metr_cpu=<v> top_cpu=<v> total=<v> warmup=<s>
#   NO-ORPHAN OK            (Metr is quit and its top child is gone within 3 s)
# or "FAIL: <reason>" with exit 1. Every number is validated as a plain number (fail closed).
# Fails when the warm-up is above 3.0 s or either log line is missing.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
# shellcheck source=../env.sh
source scripts/env.sh
# shellcheck source=lib.sh
source scripts/perf/lib.sh

SECS="${1:-30}"
case "$SECS" in
  ''|*[!0-9.]*) echo "usage: panel-cost.sh [SECONDS]" >&2; exit 2 ;;
esac

WARMUP_MAX=3.0

fail() { echo "$1"; exit 1; }

[ -d "$METR_APP_DEBUG" ] || fail "FAIL: Debug app not found at $METR_APP_DEBUG (run scripts/build.sh debug)"

# Cumulative CPU time of a pid in seconds, from ps "m:ss.cc" or "h:mm:ss" (or "d-hh:mm:ss").
cpu_seconds() {
  local raw
  raw="$(ps -o time= -p "$1" 2>/dev/null | tr -d ' ')" || true
  [ -n "$raw" ] || return 1
  awk -v t="$raw" 'BEGIN {
    days = 0
    if (index(t, "-") > 0) { split(t, d, "-"); days = d[1]; t = d[2] }
    n = split(t, p, ":")
    s = 0
    for (i = 1; i <= n; i++) s = s * 60 + p[i]
    printf "%.2f\n", days * 86400 + s
  }'
}

RUSAGE_BIN="$(metr_rusage_bin)"   # build it before the window, so compiling is not measured
mkdir -p "$METR_LOGS"
LOG="$METR_LOGS/panel-cost.log"
rm -f "$LOG"

metr_kill
trap 'metr_kill || true' EXIT

open -g -n --env "METR_DEBUG_LOG=$LOG" --env METR_DEBUG_DEMAND=panel "$METR_APP_DEBUG" \
  --args -MetrDidPresentWelcome YES
sleep 5

PID="$(metr_pid "$METR_APP_DEBUG")"
[ -n "$PID" ] || fail "FAIL: Metr did not start"
TOP_PID="$(pgrep -P "$PID" -x top | head -n 1 || true)"
[ -n "$TOP_PID" ] || fail "FAIL: no top child while panel demand is active"
echo "MEASURING pid=$PID top_pid=$TOP_PID window=${SECS}s"

TOP_BEFORE="$(cpu_seconds "$TOP_PID")" || fail "FAIL: could not read top's CPU time (pid $TOP_PID)"
LINE="$("$RUSAGE_BIN" "$PID" "$SECS")" || fail "FAIL: proc_pid_rusage failed for pid $PID"
TOP_AFTER="$(cpu_seconds "$TOP_PID")" || fail "FAIL: top (pid $TOP_PID) ended during the window"
echo "$LINE"

METR_CPU="$(printf '%s\n' "$LINE" | sed -E 's/.*cpu_pct=([0-9.]+).*/\1/')"
WALL="$(printf '%s\n' "$LINE" | sed -E 's/.*wall_s=([0-9.]+).*/\1/')"
for value in "$METR_CPU" "$WALL" "$TOP_BEFORE" "$TOP_AFTER"; do
  metr_is_number "$value" || fail "FAIL: could not parse a number (value '$value', line: $LINE)"
done
TOP_CPU="$(awk -v a="$TOP_BEFORE" -v b="$TOP_AFTER" -v w="$WALL" \
  'BEGIN { d = b - a; if (d < 0) d = 0; printf "%.3f\n", (w > 0) ? d / w * 100 : 0 }')"
TOTAL="$(awk -v a="$METR_CPU" -v b="$TOP_CPU" 'BEGIN { printf "%.3f\n", a + b }')"

# Warm-up from the debug log: first `procs n=` line to the first with ready=1.
FIRST="$(grep -m1 ' procs n=' "$LOG" 2>/dev/null | awk '{print $1}' || true)"
READY="$(grep -m1 ' procs n=.* ready=1 ' "$LOG" 2>/dev/null | awk '{print $1}' || true)"
[ -n "$FIRST" ] || fail "FAIL: no 'procs n=' line in $LOG"
[ -n "$READY" ] || fail "FAIL: no 'procs n=' line with ready=1 in $LOG (CPU never became ready)"
metr_is_number "$FIRST" && metr_is_number "$READY" || fail "FAIL: could not parse log uptimes ($FIRST, $READY)"
WARMUP="$(awk -v a="$FIRST" -v b="$READY" 'BEGIN { printf "%.3f\n", b - a }')"
metr_is_number "$WARMUP" || fail "FAIL: warm-up is not a plain number ($WARMUP)"

echo "PANEL-COST metr_cpu=$METR_CPU top_cpu=$TOP_CPU total=$TOTAL warmup=$WARMUP"
[ "$(metr_gt "$WARMUP" "$WARMUP_MAX")" = "0" ] || fail "FAIL: warm-up ${WARMUP}s is above ${WARMUP_MAX}s"

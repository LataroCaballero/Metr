#!/usr/bin/env bash
# Usage: scripts/perf/measure.sh [SECONDS] [--record]
# Idle budget gate for the Release app (FND-03): launches it, warms up 10 s, measures SECONDS
# (default 300) with proc_pid_rusage (scripts/perf/rusage.swift), checks that it holds no network
# sockets, and compares the numbers with the *_MAX thresholds in scripts/perf/budget.env.
# --record writes the measured values into budget.env (MEASURED_*), also when the gate fails.
# Prints "NO-SOCKETS OK", "NO-NETTOP OK" (nettop shows no data row for the process; otherwise
# "NETTOP TRAFFIC FOUND" with exit 1) and "BUDGET PASS cpu=<v> wakeups=<v> footprint=<v>", or
# "SOCKETS FOUND" / "BUDGET FAIL <metric>=<v> max=<v>" with exit 1.
# Also asserts the idle app has no top child (RESEARCH Pitfall 3): prints the no-top-child line,
# or "TOP CHILD FOUND" with exit 1.
# Fails closed (WR-03): "FAIL: could not parse rusage output: <line>" with exit 1 when cpu_pct,
# wakeups_per_s or footprint_mb is not a plain number; nothing is recorded or compared then.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
# shellcheck source=../env.sh
source scripts/env.sh
# shellcheck source=lib.sh
source scripts/perf/lib.sh
BUDGET="$METR_ROOT/scripts/perf/budget.env"
# shellcheck source=budget.env
source "$BUDGET"

SECS=300
RECORD=0
for arg in "$@"; do
  case "$arg" in
    --record) RECORD=1 ;;
    ''|*[!0-9.]*) echo "usage: measure.sh [SECONDS] [--record]" >&2; exit 2 ;;
    *) SECS="$arg" ;;
  esac
done

fail() { echo "$1"; exit 1; }

[ -d "$METR_APP_RELEASE" ] || fail "FAIL: Release app not found at $METR_APP_RELEASE (run scripts/build.sh release)"

metr_kill
trap 'metr_kill || true' EXIT

# The argument-domain override keeps the first-launch welcome window out of the measurement
# and leaves the owner's preferences untouched (it is not persisted).
open -g -n "$METR_APP_RELEASE" --args -MetrDidPresentWelcome YES
sleep 10
PID="$(metr_pid "$METR_APP_RELEASE")"
[ -n "$PID" ] || fail "FAIL: Metr did not start"
[ "$(metr_count)" = "1" ] || fail "FAIL: expected exactly one running Metr, found $(metr_count)"
echo "MEASURING pid=$PID app=$METR_APP_RELEASE"

RUSAGE_BIN="$(metr_rusage_bin)"
LINE="$("$RUSAGE_BIN" "$PID" "$SECS")" || fail "FAIL: proc_pid_rusage failed for pid $PID"
echo "$LINE"

# The process list's top child exists only while the panel or window is open (PROC-01, T-02-21).
if pgrep -P "$PID" -x top >/dev/null 2>&1; then
  fail "TOP CHILD FOUND"
fi
echo "NO-TOP-CHILD OK"

CPU="$(printf '%s\n' "$LINE" | sed -E 's/.*cpu_pct=([0-9.]+).*/\1/')"
WAKE="$(printf '%s\n' "$LINE" | sed -E 's/.*wakeups_per_s=([0-9.]+).*/\1/')"
FOOT="$(printf '%s\n' "$LINE" | sed -E 's/.*footprint_mb=([0-9.]+).*/\1/')"

# WR-03: sed leaves the whole line behind when a field is missing, and metr_gt coerces text to 0,
# which would pass the gate and write garbage into budget.env. Reject anything but plain numbers.
for value in "$CPU" "$WAKE" "$FOOT"; do
  metr_is_number "$value" || fail "FAIL: could not parse rusage output: $LINE"
done

# Zero-telemetry check (T-01-17): any socket line is a failure.
SOCKETS="$(lsof -a -p "$PID" -i 2>/dev/null || true)"

if [ "$RECORD" = "1" ]; then
  budget_set "$BUDGET" \
    MEASURED_CPU_PCT "$CPU" \
    MEASURED_WAKEUPS_PER_SEC "$WAKE" \
    MEASURED_FOOTPRINT_MB "$FOOT" \
    MEASURED_AT "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "RECORDED budget.env MEASURED_* (window ${SECS}s)"
fi

if [ -n "$SOCKETS" ]; then
  printf '%s\n' "$SOCKETS"
  fail "SOCKETS FOUND"
fi
echo "NO-SOCKETS OK"

# Zero-traffic check (DIST-04): nettop prints a header and a data row only for a process that moved
# bytes; any row beyond the header is a failure. Captured first: a closing pipe would SIGPIPE nettop.
NETTOP_OUT="$(nettop -P -L 1 -p "$PID" 2>/dev/null || true)"
NETTOP_ROWS="$(printf '%s\n' "$NETTOP_OUT" | sed '1d' | grep -E '[^[:space:]]' || true)"
if [ -n "$NETTOP_ROWS" ]; then
  printf '%s\n' "$NETTOP_ROWS"
  fail "NETTOP TRAFFIC FOUND"
fi
echo "NO-NETTOP OK"

[ "$(metr_gt "$CPU" "$CPU_PCT_MAX")" = "0" ] || fail "BUDGET FAIL cpu_pct=$CPU max=$CPU_PCT_MAX"
[ "$(metr_gt "$WAKE" "$WAKEUPS_PER_SEC_MAX")" = "0" ] || fail "BUDGET FAIL wakeups_per_s=$WAKE max=$WAKEUPS_PER_SEC_MAX"
[ "$(metr_gt "$FOOT" "$FOOTPRINT_MB_MAX")" = "0" ] || fail "BUDGET FAIL footprint_mb=$FOOT max=$FOOTPRINT_MB_MAX"

echo "BUDGET PASS cpu=$CPU wakeups=$WAKE footprint=$FOOT"

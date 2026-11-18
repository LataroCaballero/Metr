#!/usr/bin/env bash
# Usage: scripts/verify/table-stress.sh [ROUNDS] [RUNS] [--relhooks APP]
# The race stress for the Processes table's outline host (04-12 finding: an intermittent
# "Index out of range" crash in the data source when the group or helper lists changed).
#
# Launches the relhooks app (Release optimization with the DEBUG hooks, the only build a script can
# drive) with the window script opening Processes, and METR_DEBUG_TABLE_STRESS=ROUNDS: the table then
# stops using the live rows and feeds itself ROUNDS refreshes of churning groups and helpers (groups that
# come, go and move, helpers that appear and vanish, groups that open and close, a column change every
# 8th round), mostly spaced to land on the animated path. Before each round it also checks that the rows
# the outline shows are the rows the previous round gave it.
#
# Each run must: stay alive until the app logs "table stress done", report mismatches=0, never log a data
# source index past the end, and leave no new Metr crash report. RUNS defaults to 1, ROUNDS to 240.
# Prints "TABLE-STRESS OK runs=<n> rounds=<n> mismatches=0 crashes=0" or "FAIL: <what>" with exit 1.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
# shellcheck source=../env.sh
source scripts/env.sh

fail() { echo "FAIL: $1"; exit 1; }

ROUNDS=240
RUNS=1
relhooks="$METR_APP_RELHOOKS"
positional=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --relhooks) [ "$#" -ge 2 ] || { echo "usage: --relhooks APP" >&2; exit 2; }; relhooks="$2"; shift 2 ;;
    *)
      positional=$((positional + 1))
      if [ "$positional" = 1 ]; then ROUNDS="$1"; elif [ "$positional" = 2 ]; then RUNS="$1"; else
        echo "usage: table-stress.sh [ROUNDS] [RUNS] [--relhooks APP]" >&2; exit 2
      fi
      shift ;;
  esac
done
[[ "$ROUNDS" =~ ^[0-9]+$ && "$ROUNDS" -ge 1 ]] || fail "ROUNDS must be a positive integer"
[[ "$RUNS" =~ ^[0-9]+$ && "$RUNS" -ge 1 ]] || fail "RUNS must be a positive integer"
[ -d "$relhooks" ] || fail "$relhooks missing (scripts/build.sh relhooks first)"

reports="$HOME/Library/Logs/DiagnosticReports"
SCRIPT_SUITE="io.github.latarocaballero.Metr.script"
cleanup() {
  metr_kill >/dev/null 2>&1 || true
  defaults delete "$SCRIPT_SUITE" >/dev/null 2>&1 || true
}
trap cleanup EXIT
metr_kill

crash_count() { find "$reports" -maxdepth 1 -name 'Metr-*.ips' 2>/dev/null | wc -l | tr -d ' '; }
before_crashes="$(crash_count)"

mkdir -p "$METR_LOGS"
# A round is at most 0.5 s plus the work of the round itself: allow three times that, and a minute.
limit=$((ROUNDS * 3 / 2 + 60))

run=1
while [ "$run" -le "$RUNS" ]; do
  log="$METR_LOGS/table-stress-$run.log"
  rm -f "$log"
  defaults delete "$SCRIPT_SUITE" >/dev/null 2>&1 || true
  open -g -n \
    --env "METR_DEBUG_LOG=$log" \
    --env "METR_DEBUG_WINDOW_SCRIPT=processes@1" \
    --env "METR_DEBUG_TABLE_STRESS=$ROUNDS" \
    "$relhooks" --args -MetrDidPresentWelcome YES
  t0=$SECONDS
  done_line=""
  while [ $((SECONDS - t0)) -lt "$limit" ]; do
    pgrep -x Metr >/dev/null 2>&1 || break
    done_line="$(grep -E 'table stress done' "$log" 2>/dev/null | tail -n 1 || true)"
    [ -z "$done_line" ] || break
    sleep 1
  done
  if [ -z "$done_line" ]; then
    if pgrep -x Metr >/dev/null 2>&1; then fail "run $run: the stress did not finish within ${limit} s ($(tail -n 2 "$log" 2>/dev/null | tr '\n' ' '))"; fi
    fail "run $run: Metr exited before the stress finished (crash reports: $before_crashes before, $(crash_count) now)"
  fi
  sleep 1
  pgrep -x Metr >/dev/null 2>&1 || fail "run $run: Metr exited right after the stress"
  case "$done_line" in
    *"rounds=$ROUNDS "*"mismatches=0"*) ;;
    *) fail "run $run: unexpected result: $done_line" ;;
  esac
  if grep -q 'table datasource out-of-range' "$log"; then
    fail "run $run: the data source was asked for an index past the end ($(grep -m1 'out-of-range' "$log"))"
  fi
  metr_kill
  echo "RUN $run OK: ${done_line#* }"
  run=$((run + 1))
done

after_crashes="$(crash_count)"
[ "$after_crashes" = "$before_crashes" ] || fail "new Metr crash reports: $before_crashes before, $after_crashes after"
echo "TABLE-STRESS OK runs=$RUNS rounds=$ROUNDS mismatches=0 crashes=0"

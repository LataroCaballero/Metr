#!/usr/bin/env bash
# Usage: scripts/perf/window-cost.sh SECTION [SECONDS] [--record]
#        scripts/perf/window-cost.sh after-close [SECONDS] [--record]
#        scripts/perf/window-cost.sh cycles [N] [--record]
#
# Cost of the open Metr window per sidebar section (D-05, WIN-01), and proof that a closed window
# costs nothing (03-15). SECTION is one of cpu memory disk network gpu processes; SECONDS defaults
# to 20 (30 for after-close), N to 10.
#
# SECTION mode launches the Debug app with the window script opening SECTION (METR_DEBUG_WINDOW_SCRIPT)
# and the welcome window suppressed, waits 5 s, then checks the top child and measures Metr's own
# process with proc_pid_rusage (scripts/perf/rusage.swift) over SECONDS. Debug build, so this is an
# upper bound, and top's cost is panel-cost.sh's business, not this script's.
#   - a metric section must have NO top child; Processes must have one (the process pass);
#   - Metr's CPU must stay under WINDOW_CPU_PCT_MAX (metric sections) or
#     WINDOW_PROCESSES_CPU_PCT_MAX (processes), both from scripts/perf/budget.env;
#   - quitting Metr must take the top child with it (NO-ORPHAN OK within 3 s).
#
# after-close compares Metr with itself, not with the Release budget (a Debug build costs more): two
# fresh launches that never open the window (the baselines) and a third launch that opens CPU, then
# Processes, and closes the window at 12 s run side by side, and all three are measured for SECONDS
# starting 16 s after launch, 4 s after the close. They run at the same time, and there are two
# baselines, because an idle Debug Metr moves by 0.1 points or more between two windows of 20 to
# 40 s (the ring redraws when the Mac's own load changes) and two identical never-opened instances
# side by side differ by up to 0.05 on their own, so a single sequential baseline cannot be told
# from the 0.05 point limit. The baseline is the higher of the two. The window run fails unless
#   - no top child exists after the close;
#   - the log shows `window closed policy=accessory` and the sampler's last plan is `tier=idle`;
#   - no `history `, `net down=`, `gpu util=`, `diskio r=`, `volumes n=` or `procs n=` line follows
#     the close line;
#   - its CPU is at most the no-window baseline + 0.05 points (the limit is not loosened).
# cycles opens CPU for 2 s and closes it for 1 s, N times, in one launch, with one longer pause
# after the first close. The first open loads the window's frameworks (SwiftUI, Charts, AppKit
# tables) and Metr keeps them (about 23 MB in a Debug build); that one-time cost is printed as
# first_open_mb and is not growth. growth_mb is what the remaining N-1 cycles add: the lowest
# footprint in the 30 s after the last close minus the lowest footprint during the pause after the
# first close, a closed window both times. The lowest is used because Metr gives memory back in
# steps over about 20 s after a close (a Debug footprint falls from about 54 to 36 MB), so a single
# reading is a measurement of the timing. It fails when growth exceeds QUICK_SOAK_GROWTH_MB_MAX from
# budget.env, when a second window ever exists (count=2..9) or when the window did not open and
# close N times.
#
# The cycles gate has a KNOWN FAILURE (budget.env KNOWN_ISSUE_WINDOW_CYCLES): an AppKit scroll-pocket
# leak under fullSizeContentView, owner decision C, 2026-11-10. While growth is above the limit the
# run still prints WINDOW-COST cycles=..., then KNOWN-FAILURE, and exits 3: it never counts as a
# pass and the limit is not changed. A run at or under the limit prints a NOTE instead and exits 0; the
# result sits close to the limit, so only a repeated pass on a newer macOS or SDK is evidence of a fix.
#
# --record writes the measured values into scripts/perf/budget.env (budget_set), only after every
# check passed: MEASURED_WINDOW_CPU_PCT (cpu), MEASURED_WINDOW_PROCESSES_CPU_PCT (processes),
# MEASURED_WINDOW_AFTER_CLOSE_CPU_PCT (after-close), MEASURED_WINDOW_CYCLES_GROWTH_MB (cycles) and
# MEASURED_WINDOW_AT (UTC). No threshold is ever written.
#
# Prints
#   WINDOW-COST section=<s> metr_cpu=<v> top=<0|1> metr_wakeups=<v> metr_footprint=<v>
#   NO-ORPHAN OK (only when a top child existed; otherwise NO-ORPHAN OK means none was left)
#   WINDOW-COST after-close metr_cpu=<v> baseline=<v> (baseline_a=<v> baseline_b=<v>)
#   WINDOW-COST cycles=<n> growth_mb=<v> first_open_mb=<v>
# or "FAIL: <reason>" with exit 1. Every number is validated as a plain number (fail closed).
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
# shellcheck source=../env.sh
source scripts/env.sh
# shellcheck source=lib.sh
source scripts/perf/lib.sh
# shellcheck source=budget.env
source scripts/perf/budget.env

# WINDOW_COST_APP measures another build of the app than the Debug one, e.g. an optimized build with
# the DEBUG hooks compiled in (the real Release build has no window script and cannot be driven).
METR_APP_DEBUG="${WINDOW_COST_APP:-$METR_APP_DEBUG}"
BUDGET_FILE="$METR_ROOT/scripts/perf/budget.env"
usage_text="usage: window-cost.sh SECTION|after-close|cycles [SECONDS|N] [--record]  (SECTION: cpu memory disk network gpu processes)"

RECORD=0
ARGS=()
for arg in "$@"; do
  if [ "$arg" = "--record" ]; then RECORD=1; else ARGS+=("$arg"); fi
done
MODE="${ARGS[0]:-}"
VALUE="${ARGS[1]:-}"
[ "${#ARGS[@]}" -le 2 ] || { echo "$usage_text" >&2; exit 2; }

case "$MODE" in
  cpu|memory|disk|network|gpu|processes) SECS="${VALUE:-20}" ;;
  after-close) SECS="${VALUE:-30}" ;;
  cycles) CYCLES="${VALUE:-10}" ;;
  *) echo "$usage_text" >&2; exit 2 ;;
esac
if [ "$MODE" = "cycles" ]; then
  case "$CYCLES" in ''|*[!0-9]*) echo "$usage_text" >&2; exit 2 ;; esac
  [ "$CYCLES" -ge 1 ] || { echo "$usage_text" >&2; exit 2; }
else
  case "$SECS" in ''|*[!0-9.]*) echo "$usage_text" >&2; exit 2 ;; esac
fi

fail() { echo "$1"; exit 1; }

[ -d "$METR_APP_DEBUG" ] || fail "FAIL: Debug app not found at $METR_APP_DEBUG (run scripts/build.sh debug)"

RUSAGE_BIN="$(metr_rusage_bin)"   # build it before the window, so compiling is not measured
mkdir -p "$METR_LOGS"
trap 'metr_kill || true' EXIT

# Writes MEASURED_WINDOW_AT and the given KEY VALUE pairs into budget.env when --record was given.
record() {
  [ "$RECORD" = "1" ] || return 0
  budget_set "$BUDGET_FILE" "$@" MEASURED_WINDOW_AT "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "RECORDED $* in scripts/perf/budget.env"
}

# Launches the Debug app with the log at $1 and an optional window script $2; the welcome window is
# suppressed. Sets PID once the process is up. A third argument "keep" leaves a running Metr alone
# and picks the new process (the one that is not among the space-separated KNOWN_PIDS).
launch() {
  local log="$1" script="${2:-}" keep="${3:-}"
  rm -f "$log"
  [ "$keep" = "keep" ] || metr_kill
  if [ -n "$script" ]; then
    open -g -n --env "METR_DEBUG_LOG=$log" --env "METR_DEBUG_WINDOW_SCRIPT=$script" "$METR_APP_DEBUG" \
      --args -MetrDidPresentWelcome YES
  else
    open -g -n --env "METR_DEBUG_LOG=$log" "$METR_APP_DEBUG" --args -MetrDidPresentWelcome YES
  fi
  local i found
  for i in $(seq 1 50); do
    found="$(pgrep -f "^$METR_APP_DEBUG/Contents/MacOS/Metr( |\$)" 2>/dev/null | grep -vxFf <(printf '%s\n' ${KNOWN_PIDS:-0}) | head -n 1 || true)"
    if [ -n "$found" ]; then PID="$found"; return 0; fi
    sleep 0.1
  done
  fail "FAIL: Metr did not start"
}

# CPU percent of Metr's own process over $2 seconds (pid $1), validated as a plain number.
measure_cpu() {
  local line cpu
  line="$("$RUSAGE_BIN" "$1" "$2")" || { echo "FAIL: proc_pid_rusage failed for pid $1" >&2; exit 1; }
  echo "$line" >&2
  cpu="$(printf '%s\n' "$line" | sed -E 's/.*cpu_pct=([0-9.]+).*/\1/')"
  metr_is_number "$cpu" || { echo "FAIL: could not parse a number (value '$cpu', line: $line)" >&2; exit 1; }
  printf '%s\n' "$cpu"
}

# Footprint in MB of pid $1, validated as a plain number.
footprint_mb() {
  local line mb
  line="$("$RUSAGE_BIN" "$1" --snapshot)" || { echo "FAIL: proc_pid_rusage failed for pid $1" >&2; exit 1; }
  mb="$(printf '%s\n' "$line" | sed -E 's/.*footprint_mb=([0-9.]+).*/\1/')"
  metr_is_number "$mb" || { echo "FAIL: could not parse a footprint (line: $line)" >&2; exit 1; }
  printf '%s\n' "$mb"
}

# Sleeps until $2 seconds after the epoch second $1 (returns at once when that time has passed).
sleep_until() {
  local remaining=$(( $2 - ($(date +%s) - $1) ))
  [ "$remaining" -le 0 ] || sleep "$remaining"
}

# Lowest footprint in MB of pid $1 over $2 readings taken $3 seconds apart.
lowest_footprint() {
  local pid="$1" count="$2" gap="$3" low="" mb i
  for ((i = 0; i < count; i++)); do
    mb="$(footprint_mb "$pid")"
    if [ -z "$low" ] || [ "$(metr_gt "$low" "$mb")" = "1" ]; then low="$mb"; fi
    [ "$i" -eq $((count - 1)) ] || sleep "$gap"
  done
  printf '%s\n' "$low"
}

# ---------------------------------------------------------------- after-close

run_after_close() {
  local log_a="$METR_LOGS/window-cost-after-close-baseline-a.log"
  local log_b="$METR_LOGS/window-cost-after-close-baseline-b.log"
  local log="$METR_LOGS/window-cost-after-close.log"

  # The baselines never open the window; the third launch opens CPU, then Processes, closes at 12 s.
  KNOWN_PIDS=0
  launch "$log_a"
  local pid_a="$PID"
  KNOWN_PIDS="$pid_a"
  launch "$log_b" "" keep
  local pid_b="$PID"
  KNOWN_PIDS="$pid_a $pid_b"
  launch "$log" "cpu@1;processes@5;close@12" keep
  local win_pid="$PID"
  local launched
  launched="$(date +%s)"
  # 4 s after the close, so the last in-flight tick has long been delivered.
  sleep 16
  [ "$(( $(date +%s) - launched ))" -ge 15 ] || fail "FAIL: the close-and-wait timing slipped"
  local top_pid
  top_pid="$(pgrep -P "$win_pid" -x top | head -n 1 || true)"
  [ -z "$top_pid" ] || fail "FAIL: top child still running after the window closed (pid $top_pid)"

  local close_line
  close_line="$(grep -n 'window closed policy=accessory' "$log" | head -n 1 | cut -d: -f1 || true)"
  [ -n "$close_line" ] || fail "FAIL: no 'window closed policy=accessory' line in $log"
  grep -q 'window demand=window,windowProcesses' "$log" || fail "FAIL: the window never reached the process pass in $log"
  grep -q 'window demand=none' "$log" || fail "FAIL: the window demand never dropped to none in $log"
  # The plan change to idle is logged by the sampler's queue and can land just before the close line
  # (the close line is written one main-loop turn after the window closes), so the check is that the
  # last plan in the log is the idle one.
  local last_tier
  last_tier="$(grep -E ' tier=' "$log" | tail -n 1 || true)"
  case "$last_tier" in
    *tier=idle*) ;;
    *) fail "FAIL: the last sampling plan after the close is not tier=idle ('$last_tier')" ;;
  esac
  local window_work=' (history |net down=|gpu util=|diskio r=|volumes n=|procs n=)'
  local late
  late="$(tail -n +"$((close_line + 1))" "$log" | grep -E "$window_work" | head -n 3 || true)"
  [ -z "$late" ] || fail "FAIL: window work after the close line: $late"

  # All three over the same wall-clock seconds.
  local dir="$METR_LOGS/window-cost-after-close"
  mkdir -p "$dir"
  "$RUSAGE_BIN" "$pid_a" "$SECS" > "$dir/a.rusage" &
  local job_a=$!
  "$RUSAGE_BIN" "$pid_b" "$SECS" > "$dir/b.rusage" &
  local job_b=$!
  "$RUSAGE_BIN" "$win_pid" "$SECS" > "$dir/win.rusage" &
  local job_win=$!
  wait "$job_a" || fail "FAIL: proc_pid_rusage failed for baseline pid $pid_a"
  wait "$job_b" || fail "FAIL: proc_pid_rusage failed for baseline pid $pid_b"
  wait "$job_win" || fail "FAIL: proc_pid_rusage failed for pid $win_pid"
  echo "BASELINE-A $(cat "$dir/a.rusage")"
  echo "BASELINE-B $(cat "$dir/b.rusage")"
  echo "AFTER-CLOSE $(cat "$dir/win.rusage")"
  local cpu_a cpu_b cpu
  cpu_a="$(sed -E 's/.*cpu_pct=([0-9.]+).*/\1/' "$dir/a.rusage")"
  cpu_b="$(sed -E 's/.*cpu_pct=([0-9.]+).*/\1/' "$dir/b.rusage")"
  cpu="$(sed -E 's/.*cpu_pct=([0-9.]+).*/\1/' "$dir/win.rusage")"
  metr_is_number "$cpu_a" || fail "FAIL: could not parse the first baseline cpu ('$cpu_a')"
  metr_is_number "$cpu_b" || fail "FAIL: could not parse the second baseline cpu ('$cpu_b')"
  metr_is_number "$cpu" || fail "FAIL: could not parse the after-close cpu ('$cpu')"
  local base_cpu
  base_cpu="$(awk -v a="$cpu_a" -v b="$cpu_b" 'BEGIN { printf "%.3f", (a + 0 > b + 0) ? a : b }')"

  # Nothing may have restarted while measuring.
  top_pid="$(pgrep -P "$win_pid" -x top | head -n 1 || true)"
  [ -z "$top_pid" ] || fail "FAIL: top child appeared after the window closed (pid $top_pid)"
  late="$(tail -n +"$((close_line + 1))" "$log" | grep -E "$window_work" | head -n 3 || true)"
  [ -z "$late" ] || fail "FAIL: window work after the close line: $late"

  echo "WINDOW-COST after-close metr_cpu=$cpu baseline=$base_cpu (baseline_a=$cpu_a baseline_b=$cpu_b)"
  local limit
  limit="$(awk -v b="$base_cpu" 'BEGIN { printf "%.3f", b + 0.05 }')"
  [ "$(metr_gt "$cpu" "$limit")" = "0" ] || fail "FAIL: after-close cpu $cpu above the no-window baseline $base_cpu + 0.05"
  record MEASURED_WINDOW_AFTER_CLOSE_CPU_PCT "$cpu"
  metr_kill
}

# --------------------------------------------------------------------- cycles

run_cycles() {
  local n="$CYCLES" log="$METR_LOGS/window-cost-cycles.log"
  local limit="${QUICK_SOAK_GROWTH_MB_MAX:-}"
  metr_is_number "$limit" || fail "FAIL: QUICK_SOAK_GROWTH_MB_MAX is not a plain number in budget.env ('$limit')"

  # The first open is at 8 s, so the "before" footprint is read at about 5 s with no window ever
  # opened. Cycle 1 closes at 10 s and the window stays closed until 28 s (long enough for the
  # memory to be given back, see the header); every later cycle keeps CPU open for 2 s and closed
  # for 1 s.
  local script="cpu@8;close@10" i open last_close=10
  for ((i = 1; i < n; i++)); do
    open=$((28 + 3 * (i - 1)))
    script+=";cpu@${open};close@$((open + 2))"
    last_close=$((open + 2))
  done

  launch "$log" "$script"
  local launched
  launched="$(date +%s)"
  sleep 5
  local before
  before="$(footprint_mb "$PID")"
  # The pause: closed from 10 s to 28 s; read the lowest footprint from 13 s to 27 s.
  sleep_until "$launched" 13
  local settled
  settled="$(lowest_footprint "$PID" 8 2)"
  # The tail: the lowest footprint from 3 s to 33 s after the last close.
  sleep_until "$launched" "$((last_close + 3))"
  kill -0 "$PID" 2>/dev/null || fail "FAIL: Metr exited during the open and close cycles"
  local after
  after="$(lowest_footprint "$PID" 15 2)"
  local growth first_open
  growth="$(awk -v a="$after" -v b="$settled" 'BEGIN { g = a - b; if (g < 0) g = 0; printf "%.1f", g }')"
  first_open="$(awk -v a="$settled" -v b="$before" 'BEGIN { g = a - b; if (g < 0) g = 0; printf "%.1f", g }')"
  echo "FOOTPRINT before_first_open=$before lowest_in_pause=$settled lowest_after_last_close=$after"

  local shown closed
  shown="$(grep -cE ' window shown section=cpu count=' "$log" || true)"
  closed="$(grep -c 'window closed policy=accessory' "$log" || true)"
  [ "$shown" = "$n" ] || fail "FAIL: the window opened $shown times, expected $n (see $log)"
  [ "$closed" = "$n" ] || fail "FAIL: the window closed $closed times, expected $n (see $log)"
  if grep -qE ' window shown .* count=[2-9]' "$log"; then
    fail "FAIL: a second Metr window existed at once (count=2 or more in $log)"
  fi

  echo "WINDOW-COST cycles=$n growth_mb=$growth first_open_mb=$first_open"
  if [ "$(metr_gt "$growth" "$limit")" = "1" ]; then
    echo "FAIL: memory grew by $growth MB over the $((n - 1)) cycles after the first, above $limit MB"
    if [ -n "${KNOWN_ISSUE_WINDOW_CYCLES:-}" ]; then
      echo "KNOWN-FAILURE cycles: $KNOWN_ISSUE_WINDOW_CYCLES"
      metr_kill
      exit 3
    fi
    exit 1
  fi
  [ -z "${KNOWN_ISSUE_WINDOW_CYCLES:-}" ] || echo "NOTE: cycles passed this run, but KNOWN_ISSUE_WINDOW_CYCLES is still set in budget.env; the result sits near the limit and a pass is only evidence once it repeats on a newer macOS or SDK (retire the known issue with the owner)"
  record MEASURED_WINDOW_CYCLES_GROWTH_MB "$growth"
  metr_kill
}

case "$MODE" in
  after-close) run_after_close; exit 0 ;;
  cycles) run_cycles; exit 0 ;;
esac

# -------------------------------------------------------------- SECTION mode

SECTION="$MODE"
if [ "$SECTION" = "processes" ]; then
  BUDGET="${WINDOW_PROCESSES_CPU_PCT_MAX:-}"
else
  BUDGET="${WINDOW_CPU_PCT_MAX:-}"
fi
metr_is_number "$BUDGET" || fail "FAIL: window budget for $SECTION is not a plain number in budget.env ('$BUDGET')"

LOG="$METR_LOGS/window-cost-$SECTION.log"
rm -f "$LOG"

metr_kill

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
METR_WAKEUPS="$(printf '%s\n' "$LINE" | sed -E 's/.*wakeups_per_s=([0-9.]+).*/\1/')"
METR_FOOTPRINT="$(printf '%s\n' "$LINE" | sed -E 's/.*footprint_mb=([0-9.]+).*/\1/')"
metr_is_number "$METR_WAKEUPS" && metr_is_number "$METR_FOOTPRINT" || fail "FAIL: could not parse wakeups or footprint (line: $LINE)"

# The top child must still agree with the section after the measuring window (no late start).
if [ "$SECTION" != "processes" ]; then
  LATE="$(pgrep -P "$PID" -x top | head -n 1 || true)"
  [ -z "$LATE" ] || fail "FAIL: top child appeared with $SECTION selected (pid $LATE)"
fi

echo "WINDOW-COST section=$SECTION metr_cpu=$METR_CPU top=$TOP metr_wakeups=$METR_WAKEUPS metr_footprint=$METR_FOOTPRINT"
[ "$(metr_gt "$METR_CPU" "$BUDGET")" = "0" ] || fail "FAIL: window cpu $METR_CPU above $BUDGET"

# Only the cpu and processes sections have a recorded value; the others are gated, not recorded.
case "$SECTION" in
  cpu) record MEASURED_WINDOW_CPU_PCT "$METR_CPU" ;;
  processes) record MEASURED_WINDOW_PROCESSES_CPU_PCT "$METR_CPU" ;;
  *) [ "$RECORD" = "0" ] || echo "NOTE: $SECTION has no MEASURED_WINDOW_* key; nothing recorded" ;;
esac

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

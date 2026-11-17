#!/usr/bin/env bash
# Usage: scripts/verify/procs-vs-top.sh
# PROC-01 accuracy: runs the Debug app with the panel demand forced on (the shipping
# ProcessCollector -> TopStream -> MetricsStore pipeline) next to a load and compares the
# probe lines it logs for WindowServer, Finder and a busy `yes` with top's own figures:
#   - the system rows are present with other-uid processes merged (sys=available),
#   - memory is the physical footprint (WindowServer ~0.5 GB, not its ~65 MB RSS),
#   - the CPU of a process the app can only know through top agrees with top.
# Prints the success line (ws_mem, finder_mem and yes_cpu as <app>/<top> pairs) or "FAIL: <what>".
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
# shellcheck source=../env.sh
source scripts/env.sh

fail() { echo "FAIL: $1"; exit 1; }

[ -d "$METR_APP_DEBUG" ] || fail "Debug app not found at $METR_APP_DEBUG (run scripts/build.sh debug first)"

mkdir -p "$METR_LOGS"
TOP_OUT="$METR_LOGS/procs-vs-top.top"
APP_LOG="$METR_LOGS/procs-vs-top.log"

pids=()
cleanup() {
  local p
  for p in "${pids[@]+"${pids[@]}"}"; do
    kill "$p" 2>/dev/null || true
  done
}
trap cleanup EXIT

yes > /dev/null &
YES_PID="$!"
pids+=("$YES_PID")

WS_PID="$(pgrep -x WindowServer | head -n 1 || true)"
FINDER_PID="$(pgrep -x Finder | head -n 1 || true)"
[ -n "$WS_PID" ] || fail "WindowServer is not running"
[ -n "$FINDER_PID" ] || fail "Finder is not running"
sleep 1

# 7 samples every 2 s cover the app's 14 s run; sample 1 has no CPU baseline.
LC_ALL=C top -l 7 -s 2 -stats pid,cpu,mem -pid "$WS_PID" -pid "$FINDER_PID" -pid "$YES_PID" > "$TOP_OUT" &
pids+=("$!")
TOP_PID="$!"

bash scripts/verify/run-debug.sh 14 procs-vs-top \
  --env METR_DEBUG_DEMAND=panel \
  --env "METR_DEBUG_PROBE_PIDS=$WS_PID,$FINDER_PID,$YES_PID" \
  --expect 'procs n=[0-9]+ own=[0-9]+ other=[0-9]{2,} ready=1 sys=available' --min 3 \
  --expect "probe pid=$WS_PID mem=[0-9]+" --min 3 \
  --args -MetrDidPresentWelcome YES

wait "$TOP_PID" 2>/dev/null || true

# Median of the numbers on stdin.
median() {
  sort -g | awk '{ v[NR] = $1 } END { if (NR == 0) exit 1; print (NR % 2) ? v[(NR + 1) / 2] : (v[NR / 2] + v[NR / 2 + 1]) / 2 }'
}

# top MEM column (K/M/G/B with a trailing +/- trend mark) to bytes, for one pid, every sample.
top_mem_bytes() {
  awk -v pid="$1" '$1 == pid && NF == 3 {
    m = $3; sub(/[+-]$/, "", m); u = substr(m, length(m)); n = substr(m, 1, length(m) - 1) + 0
    if (u == "K") n *= 1024; else if (u == "M") n *= 1048576; else if (u == "G") n *= 1073741824
    printf "%.0f\n", n }' "$TOP_OUT"
}

app_mem_bytes() {
  grep -E "probe pid=$1 mem=[0-9]+" "$APP_LOG" | sed -E 's/.*mem=([0-9]+).*/\1/'
}

within() { # within APP TOP: |app - top| <= max(8 MiB, 3 % of top)
  awk -v a="$1" -v t="$2" 'BEGIN { d = a - t; if (d < 0) d = -d; tol = t * 0.03; if (tol < 8388608) tol = 8388608; exit !(d <= tol) }'
}

check_mem() { # check_mem NAME PID
  # Runs inside $(...): its stdout is the result, so a failure message goes to stderr or it is swallowed
  # (a preflight run once lost the reason of an intermittent failure this way).
  local app top
  app="$(app_mem_bytes "$2" | median)" || { echo "FAIL: no $1 memory probe lines in $APP_LOG" >&2; exit 1; }
  top="$(top_mem_bytes "$2" | median)" || { echo "FAIL: no $1 rows in $TOP_OUT" >&2; exit 1; }
  within "$app" "$top" || { echo "FAIL: $1 memory app=$app top=$top differ by more than max(8 MiB, 3 %)" >&2; exit 1; }
  echo "$app/$top"
}

ws_mem="$(check_mem WindowServer "$WS_PID")"
finder_mem="$(check_mem Finder "$FINDER_PID")"

# yes: the app's numeric CPU values vs top's from the second sample on.
app_cpu="$(grep -E "probe pid=$YES_PID mem=[0-9]+ cpu=[0-9.]+" "$APP_LOG" | sed -E 's/.*cpu=([0-9.]+).*/\1/' | median)" \
  || fail "no numeric yes CPU probe lines in $APP_LOG"
top_cpu="$(awk -v pid="$YES_PID" '$1 == pid && NF == 3 { n++; if (n > 1) print $2 }' "$TOP_OUT" | median)" \
  || fail "no yes CPU rows after the first sample in $TOP_OUT"
awk -v a="$app_cpu" 'BEGIN { exit !(a >= 80) }' || fail "yes CPU app=$app_cpu is below 80"
awk -v a="$app_cpu" -v t="$top_cpu" 'BEGIN { d = a - t; if (d < 0) d = -d; exit !(d <= 10) }' \
  || fail "yes CPU app=$app_cpu top=$top_cpu differ by more than 10 points"

echo "PROCS-VS-TOP OK ws_mem=$ws_mem finder_mem=$finder_mem yes_cpu=$app_cpu/$top_cpu"

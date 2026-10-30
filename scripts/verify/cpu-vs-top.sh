#!/usr/bin/env bash
# Usage: scripts/verify/cpu-vs-top.sh
# CPU-01 accuracy: runs the Debug app (the shipping CPUCollector -> MetricsSampler -> MetricsStore
# pipeline) under a steady 4-process load and compares its logged CPU % with top's (100 - idle)
# over the same window, and its logged user and system % with top's user and sys (PANEL-01).
# Prints "CPU-VS-TOP OK app=<v> top=<v> diff=<v> user=<app>/<top> sys=<app>/<top>" or "FAIL: <what>".
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
# shellcheck source=../env.sh
source scripts/env.sh

fail() { echo "FAIL: $1"; exit 1; }

[ -d "$METR_APP_DEBUG" ] || fail "Debug app not found at $METR_APP_DEBUG (run scripts/build.sh debug first)"

mkdir -p "$METR_LOGS"
TOP_OUT="$METR_LOGS/cpu-vs-top.top"
APP_LOG="$METR_LOGS/cpu-vs-top.log"
TOLERANCE=3.0

pids=()
cleanup() {
  local p
  for p in "${pids[@]+"${pids[@]}"}"; do
    kill "$p" 2>/dev/null || true
  done
}
trap cleanup EXIT

for _ in 1 2 3 4; do
  yes > /dev/null &
  pids+=("$!")
done
sleep 1

top -l 9 -s 2 -n 0 > "$TOP_OUT" &
pids+=("$!")
TOP_PID="$!"

bash scripts/verify/run-debug.sh 16 cpu-vs-top --expect 'batch cpu=[01]\.[0-9]{2}' --min 5 \
  --args -MetrDidPresentWelcome YES

wait "$TOP_PID" 2>/dev/null || true

# top: discard the first sample (since boot), mean of 100 - idle over the rest.
top_mean="$(grep -E '^CPU usage:' "$TOP_OUT" | sed '1d' \
  | awk '{ for (i = 1; i <= NF; i++) if ($i == "idle") { v = $(i - 1); sub(/%/, "", v); s += 100 - v; n++ } }
         END { if (n == 0) exit 1; printf "%.2f", s / n }')" || fail "no usable 'CPU usage:' lines in $TOP_OUT"

# app: skip the first batch value, mean x 100.
app_mean="$(grep -E 'batch cpu=[01]\.[0-9]{2}' "$APP_LOG" | sed '1d' \
  | sed -E 's/.*batch cpu=([01]\.[0-9]+).*/\1/' \
  | awk '{ s += $1 * 100; n++ } END { if (n == 0) exit 1; printf "%.2f", s / n }')" || fail "no usable batch lines in $APP_LOG"

# top: mean of the user and sys percentages over the same samples (first one discarded).
read -r top_user top_sys < <(grep -E '^CPU usage:' "$TOP_OUT" | sed '1d' \
  | awk '{ for (i = 1; i <= NF; i++) { if ($i == "user,") { v = $(i - 1); sub(/%/, "", v); u += v }
                                       if ($i == "sys,")  { v = $(i - 1); sub(/%/, "", v); y += v } }
           n++ }
         END { if (n == 0) exit 1; printf "%.2f %.2f\n", u / n, y / n }') || fail "no usable user/sys in $TOP_OUT"

# app: the cpuuser= and cpusys= tokens of the same batch lines (first skipped), x 100.
app_user="$(grep -E 'cpuuser=[01]\.[0-9]{2} cpusys=' "$APP_LOG" | sed '1d' \
  | sed -E 's/.*cpuuser=([01]\.[0-9]+).*/\1/' \
  | awk '{ s += $1 * 100; n++ } END { if (n == 0) exit 1; printf "%.2f", s / n }')" || fail "no cpuuser tokens in $APP_LOG"
app_sys="$(grep -E 'cpuuser=[01]\.[0-9]{2} cpusys=' "$APP_LOG" | sed '1d' \
  | sed -E 's/.*cpusys=([01]\.[0-9]+).*/\1/' \
  | awk '{ s += $1 * 100; n++ } END { if (n == 0) exit 1; printf "%.2f", s / n }')" || fail "no cpusys tokens in $APP_LOG"

absdiff() { awk -v a="$1" -v b="$2" 'BEGIN { d = a - b; if (d < 0) d = -d; printf "%.2f", d }'; }
exceeds() { awk -v d="$1" -v tol="$TOLERANCE" 'BEGIN { exit !(d > tol) }'; }

diff="$(absdiff "$app_mean" "$top_mean")"
user_diff="$(absdiff "$app_user" "$top_user")"
sys_diff="$(absdiff "$app_sys" "$top_sys")"

exceeds "$diff" && fail "app=$app_mean top=$top_mean diff=$diff exceeds $TOLERANCE points"
exceeds "$user_diff" && fail "user app=$app_user top=$top_user diff=$user_diff exceeds $TOLERANCE points"
exceeds "$sys_diff" && fail "sys app=$app_sys top=$top_sys diff=$sys_diff exceeds $TOLERANCE points"

echo "CPU-VS-TOP OK app=$app_mean top=$top_mean diff=$diff user=$app_user/$top_user sys=$app_sys/$top_sys"

#!/usr/bin/env bash
# Usage: scripts/verify/cpu-vs-top.sh
# CPU-01 accuracy: runs the Debug app (the shipping CPUCollector -> MetricsSampler -> MetricsStore
# pipeline) under a steady 4-process load and compares its logged CPU % with top's (100 - idle)
# over the same window. Prints "CPU-VS-TOP OK app=<v> top=<v> diff=<v>" or "FAIL: <what>".
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

bash scripts/verify/run-debug.sh 16 cpu-vs-top --expect 'batch cpu=[01]\.[0-9]{2}' --min 5

wait "$TOP_PID" 2>/dev/null || true

# top: discard the first sample (since boot), mean of 100 - idle over the rest.
top_mean="$(grep -E '^CPU usage:' "$TOP_OUT" | sed '1d' \
  | awk '{ for (i = 1; i <= NF; i++) if ($i == "idle") { v = $(i - 1); sub(/%/, "", v); s += 100 - v; n++ } }
         END { if (n == 0) exit 1; printf "%.2f", s / n }')" || fail "no usable 'CPU usage:' lines in $TOP_OUT"

# app: skip the first batch value, mean x 100.
app_mean="$(grep -E 'batch cpu=[01]\.[0-9]{2}' "$APP_LOG" | sed '1d' \
  | sed -E 's/.*batch cpu=([01]\.[0-9]+).*/\1/' \
  | awk '{ s += $1 * 100; n++ } END { if (n == 0) exit 1; printf "%.2f", s / n }')" || fail "no usable batch lines in $APP_LOG"

diff="$(awk -v a="$app_mean" -v t="$top_mean" 'BEGIN { d = a - t; if (d < 0) d = -d; printf "%.2f", d }')"

if awk -v d="$diff" -v tol="$TOLERANCE" 'BEGIN { exit !(d > tol) }'; then
  fail "app=$app_mean top=$top_mean diff=$diff exceeds $TOLERANCE points"
fi

echo "CPU-VS-TOP OK app=$app_mean top=$top_mean diff=$diff"

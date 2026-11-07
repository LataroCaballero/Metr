#!/usr/bin/env bash
# Usage: scripts/verify/gpu-vs-ioreg.sh
# Proves the GPU reading agrees with the system's own registry (GPU-01). It runs the Debug app for
# 12 s with the window open on GPU, and once the first "gpu util=" line is logged it samples
# `ioreg -r -c IOAccelerator -w 0` eight times, one second apart, parsing every "Device Utilization %"
# and "gpu-core-count". It fails when the logged core count differs from ioreg's, or when
# |mean(app) - mean(ioreg) / 100| is above 0.15 (the busiest accelerator is compared on both sides).
# Prints "GPU-VS-IOREG OK app=<m> ioreg=<m> cores=<n>", otherwise "FAIL: <what>" with exit 1.
# Always launches with -MetrDidPresentWelcome YES so the owner's preferences stay untouched.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
# shellcheck source=../env.sh
source scripts/env.sh

fail() { echo "FAIL: $1"; exit 1; }

[ -d "$METR_APP_DEBUG" ] || fail "Debug app not found at $METR_APP_DEBUG (run scripts/build.sh debug)"

mkdir -p "$METR_LOGS"
LOG="$METR_LOGS/gpu-vs-ioreg.log"
SAMPLES="$METR_LOGS/gpu-vs-ioreg-ioreg.txt"
rm -f "$LOG" "$SAMPLES"
: > "$SAMPLES"

SAMPLER=""
cleanup() {
  if [ -n "$SAMPLER" ] && kill -0 "$SAMPLER" 2>/dev/null; then kill "$SAMPLER" 2>/dev/null || true; fi
  metr_kill || true
}
trap cleanup EXIT

(
  i=0
  until grep -Eq 'gpu util=' "$LOG" 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -le 100 ] || exit 1
    sleep 0.1
  done
  for _ in 1 2 3 4 5 6 7 8; do
    out="$(ioreg -r -c IOAccelerator -w 0)"
    # One line per sample: the busiest accelerator's utilization, then the largest core count.
    util="$(printf '%s\n' "$out" | grep -Eo '"Device Utilization %"=[0-9]+' | cut -d= -f2 | sort -n | tail -n 1 || true)"
    cores="$(printf '%s\n' "$out" | grep -Eo '"gpu-core-count" = [0-9]+' | awk '{print $3}' | sort -n | tail -n 1 || true)"
    echo "${util:-} ${cores:-}" >> "$SAMPLES"
    sleep 1
  done
) &
SAMPLER=$!

bash scripts/verify/run-debug.sh 12 gpu-vs-ioreg \
  --env 'METR_DEBUG_WINDOW_SCRIPT=gpu@1' \
  --expect 'gpu util=[01]\.[0-9]{2} cores=[0-9]+' --min 6 \
  --args -MetrDidPresentWelcome YES

wait "$SAMPLER" || fail "the ioreg sampler exited non-zero (no gpu line appeared in 10 s)"
SAMPLER=""

app_cores="$(grep -Eo 'gpu util=[01]\.[0-9]{2} cores=[0-9]+' "$LOG" | sed -E 's/.*cores=//' | sort -u)"
[ "$(printf '%s\n' "$app_cores" | wc -l | tr -d ' ')" = "1" ] || fail "the app logged more than one core count: $(echo $app_cores)"
ioreg_cores="$(awk 'NF == 2 { print $2 }' "$SAMPLES" | sort -u)"
[ "$(printf '%s\n' "$ioreg_cores" | grep -c .)" = "1" ] || fail "ioreg gave no single gpu-core-count (got '$(echo $ioreg_cores)')"
[ "$app_cores" = "$ioreg_cores" ] || fail "core count differs: app=$app_cores ioreg=$ioreg_cores"

app_mean="$(grep -Eo 'gpu util=[01]\.[0-9]{2}' "$LOG" | sed -E 's/.*util=//' | awk '{ s += $1; n++ } END { if (n) printf "%.3f", s / n }')"
ioreg_mean="$(awk 'NF >= 1 && $1 ~ /^[0-9]+$/ { s += $1; n++ } END { if (n) printf "%.3f", s / n / 100 }' "$SAMPLES")"
[ -n "$app_mean" ] || fail "no app GPU values"
[ -n "$ioreg_mean" ] || fail "no ioreg utilization values (see $SAMPLES)"

verdict="$(awk -v a="$app_mean" -v b="$ioreg_mean" 'BEGIN { d = a - b; if (d < 0) d = -d; print (d > 0.15) ? "differ" : "ok" }')"
[ "$verdict" = "ok" ] || fail "mean GPU differs: app=$app_mean ioreg=$ioreg_mean (limit 0.15)"

echo "GPU-VS-IOREG OK app=$app_mean ioreg=$ioreg_mean cores=$app_cores"

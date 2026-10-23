#!/usr/bin/env bash
# Usage: scripts/verify/tick-intervals.sh NAME_OR_PATH EXPECTED TOLERANCE
# Reads "tick dt=X" lines from a run-debug log (a bare NAME resolves to $METR_LOGS/NAME.log),
# skips the first tick, and asserts |median - EXPECTED| <= TOLERANCE.
# Prints "TICK-INTERVALS OK median=<v> n=<n>" or "FAIL: <why>" with exit 1.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
# shellcheck source=../env.sh
source scripts/env.sh

fail() { echo "FAIL: $1"; exit 1; }

[ "$#" -eq 3 ] || { echo "usage: tick-intervals.sh NAME_OR_PATH EXPECTED TOLERANCE" >&2; exit 2; }
target="$1"; expected="$2"; tolerance="$3"

case "$target" in
  */*) log="$target" ;;
  *)   log="$METR_LOGS/$target.log" ;;
esac
[ -f "$log" ] || fail "log not found: $log"

values="$(grep -E 'tick dt=' "$log" | sed -E 's/.*tick dt=([0-9.]+).*/\1/' | tail -n +2)"
n="$(printf '%s\n' "$values" | grep -c . || true)"
[ "$n" -ge 3 ] || fail "need at least 3 tick intervals after the first tick, found $n (log=$log)"

median="$(printf '%s\n' "$values" | sort -n | awk '{ a[NR] = $1 } END { if (NR % 2) print a[(NR + 1) / 2]; else printf "%.3f\n", (a[NR / 2] + a[NR / 2 + 1]) / 2 }')"

ok="$(awk -v m="$median" -v e="$expected" -v t="$tolerance" 'BEGIN { d = m - e; if (d < 0) d = -d; print (d <= t) ? 1 : 0 }')"
[ "$ok" = "1" ] || fail "median $median is outside $expected +/- $tolerance (n=$n, log=$log)"

echo "TICK-INTERVALS OK median=$median n=$n"

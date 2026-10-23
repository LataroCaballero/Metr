#!/usr/bin/env bash
# Usage: scripts/verify/run-debug.sh SECONDS NAME
#          [--env KEY=VALUE]...
#          [--expect REGEX [--min N] [--max N]]...
#          [--reject REGEX]...
#          [--args ARG...]
# Launches the Debug app with METR_DEBUG_LOG=$METR_LOGS/NAME.log, waits, quits it, and asserts
# on the log. Prints "LOG=<path>" and "RUN-DEBUG OK", or "FAIL: <what>" with exit 1.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
# shellcheck source=../env.sh
source scripts/env.sh

fail() { echo "FAIL: $1"; exit 1; }

[ "$#" -ge 2 ] || { echo "usage: run-debug.sh SECONDS NAME [options]" >&2; exit 2; }
SECS="$1"; NAME="$2"; shift 2

envs=()
expect_re=(); expect_min=(); expect_max=()
rejects=()
app_args=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --env)    envs+=("$2"); shift 2 ;;
    --expect) expect_re+=("$2"); expect_min+=(1); expect_max+=(-1); shift 2 ;;
    --min)
      [ "${#expect_re[@]}" -gt 0 ] || fail "--min without a preceding --expect"
      expect_min[$(( ${#expect_re[@]} - 1 ))]="$2"; shift 2 ;;
    --max)
      [ "${#expect_re[@]}" -gt 0 ] || fail "--max without a preceding --expect"
      expect_max[$(( ${#expect_re[@]} - 1 ))]="$2"; shift 2 ;;
    --reject) rejects+=("$2"); shift 2 ;;
    --args)   shift; app_args=("$@"); break ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

[ -d "$METR_APP_DEBUG" ] || fail "Debug app not found at $METR_APP_DEBUG (run scripts/build.sh debug)"

mkdir -p "$METR_LOGS"
LOG="$METR_LOGS/$NAME.log"

metr_kill
: > "$LOG"

open_args=(-g -n --env "METR_DEBUG_LOG=$LOG")
for e in "${envs[@]+"${envs[@]}"}"; do
  open_args+=(--env "$e")
done
open_args+=("$METR_APP_DEBUG")
if [ "${#app_args[@]}" -gt 0 ]; then
  open_args+=(--args "${app_args[@]}")
fi
open "${open_args[@]}"

sleep "$SECS"
metr_kill

i=0
while [ "$i" -lt "${#expect_re[@]}" ]; do
  re="${expect_re[$i]}"
  count="$(grep -Ec -- "$re" "$LOG" || true)"
  [ "$count" -ge "${expect_min[$i]}" ] || fail "expected at least ${expect_min[$i]} line(s) matching '$re', found $count (LOG=$LOG)"
  if [ "${expect_max[$i]}" -ge 0 ] && [ "$count" -gt "${expect_max[$i]}" ]; then
    fail "expected at most ${expect_max[$i]} line(s) matching '$re', found $count (LOG=$LOG)"
  fi
  i=$((i + 1))
done

for re in "${rejects[@]+"${rejects[@]}"}"; do
  if grep -Eq -- "$re" "$LOG"; then
    fail "log contains rejected pattern '$re' (LOG=$LOG)"
  fi
done

echo "LOG=$LOG"
echo "RUN-DEBUG OK"

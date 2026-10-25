#!/usr/bin/env bash
# Usage: scripts/verify/disk-live.sh [MIB]      (default 256)
# Proves CR-01 stays fixed: the RUNNING Debug app's disk reading refreshes. It launches the app at
# 0.05x cadence (disk sampled at launch, then every 3 s), writes MIB MiB to a temp file on the
# startup volume once the first numeric "diskfree=" value is logged, and compares the first and
# last logged free-byte counts.
# Prints "DISK-LIVE OK before=<b> after=<b> delta=<b> alloc=<b>" when free space dropped by at
# least half the allocation, otherwise "DISK-LIVE FAIL ..." or "FAIL: <what>" with exit 1.
# Always launches with -MetrDidPresentWelcome YES so the owner's preferences stay untouched.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
# shellcheck source=../env.sh
source scripts/env.sh

fail() { echo "FAIL: $1"; exit 1; }

MIB="${1:-256}"
[[ "$MIB" =~ ^[1-9][0-9]*$ ]] || fail "MIB must be a positive integer (got '$MIB')"
[ -d "$METR_APP_DEBUG" ] || fail "Debug app not found at $METR_APP_DEBUG (run scripts/build.sh debug)"

TMP="${TMPDIR:-/tmp}"
avail_kib="$(df -k "$TMP" | awk 'NR == 2 { print $4 }')"
need_kib=$(( (MIB + 2048) * 1024 ))
[ "$avail_kib" -ge "$need_kib" ] || fail "not enough free space on $TMP (have ${avail_kib} KiB, need ${need_kib} KiB)"

mkdir -p "$METR_LOGS"
LOG="$METR_LOGS/disk-live.log"
rm -f "$LOG"
FILE="$(mktemp "$TMP/metr-disk-live.XXXXXX")"
WRITER=""

cleanup() {
  if [ -n "$WRITER" ] && kill -0 "$WRITER" 2>/dev/null; then kill "$WRITER" 2>/dev/null || true; fi
  rm -f "$FILE"
  metr_kill || true
}
trap cleanup EXIT

(
  i=0
  until grep -Eq 'diskfree=[0-9]' "$LOG" 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -le 100 ] || exit 1
    sleep 0.2
  done
  dd if=/dev/urandom of="$FILE" bs=1048576 count="$MIB" 2>/dev/null
  sync
) &
WRITER=$!

bash scripts/verify/run-debug.sh 16 disk-live \
  --env METR_DEBUG_CADENCE_SCALE=0.05 \
  --expect 'diskfree=[0-9]+' --min 3 \
  --args -MetrDidPresentWelcome YES

wait "$WRITER" || fail "the allocation writer exited non-zero (no numeric diskfree= value appeared in 20 s, or dd failed)"
WRITER=""

values="$(grep -Eo 'diskfree=[0-9]+' "$LOG" | cut -d= -f2)"
before="$(printf '%s\n' "$values" | head -n 1)"
after="$(printf '%s\n' "$values" | tail -n 1)"
alloc=$(( MIB * 1048576 ))
need=$(( alloc / 2 ))
delta=$(( before - after ))

if [ "$delta" -ge "$need" ]; then
  echo "DISK-LIVE OK before=$before after=$after delta=$delta alloc=$alloc"
else
  echo "DISK-LIVE FAIL before=$before after=$after delta=$delta need=$need"
  exit 1
fi

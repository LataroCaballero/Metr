#!/usr/bin/env bash
# Usage: scripts/verify/diskio-live.sh
# Proves the system-wide disk write rate of the RUNNING Debug app (WIN-02, D-08) follows a real
# write burst. It runs the app 16 s with the window opened on Disk (METR_DEBUG_WINDOW_SCRIPT=disk@1,
# through run-debug.sh), and from about 5 s to 11 s a python3 writer overwrites one 64 MiB file
# under $TMPDIR in 8 MiB chunks with an fsync after each chunk. The file is on the internal disk
# (preflight guarantees 2 GiB free), is only ever overwritten in place, and a trap deletes it.
#
# The writer stamps its own start and end on the same clock the app's log lines carry (system
# uptime without sleep, CLOCK_UPTIME_RAW), so the log is split by time, not by line order. Fails
# unless the largest logged `w=` during the burst is at least 20_000_000 B/s and above the largest
# one before it.
# Prints "DISKIO-LIVE OK max_w=<B/s>" or "FAIL: <what>" with exit 1.
# Always launches with -MetrDidPresentWelcome YES so the owner's preferences stay untouched.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
# shellcheck source=../env.sh
source scripts/env.sh

fail() { echo "FAIL: $1"; exit 1; }

[ -d "$METR_APP_DEBUG" ] || fail "Debug app not found at $METR_APP_DEBUG (run scripts/build.sh debug)"

TMP="${TMPDIR:-/tmp}"
avail_kib="$(df -k "$TMP" | awk 'NR == 2 { print $4 }')"
[ "$avail_kib" -ge $(( 2 * 1024 * 1024 )) ] || fail "not enough free space on $TMP (have ${avail_kib} KiB, need 2 GiB)"

mkdir -p "$METR_LOGS"
LOG="$METR_LOGS/diskio-live.log"
STAMP="$METR_LOGS/diskio-live.stamp"
rm -f "$LOG" "$STAMP"
FILE="$(mktemp "$TMP/metr-diskio-live.XXXXXX")"
WRITER=""

cleanup() {
  if [ -n "$WRITER" ] && kill -0 "$WRITER" 2>/dev/null; then kill "$WRITER" 2>/dev/null || true; fi
  rm -f "$FILE"
  metr_kill || true
}
trap cleanup EXIT

(
  sleep 5
  python3 -I -c '
import os, sys, time
path, seconds = sys.argv[1], float(sys.argv[2])
chunk = os.urandom(8 * 1024 * 1024)
start = time.clock_gettime(time.CLOCK_UPTIME_RAW)
fd = os.open(path, os.O_WRONLY)
try:
    while time.clock_gettime(time.CLOCK_UPTIME_RAW) - start < seconds:
        os.lseek(fd, 0, os.SEEK_SET)
        for _ in range(8):  # 8 x 8 MiB = the 64 MiB file, overwritten in place
            os.write(fd, chunk)
            os.fsync(fd)
finally:
    os.close(fd)
end = time.clock_gettime(time.CLOCK_UPTIME_RAW)
print("%.3f %.3f" % (start, end))
' "$FILE" 6 > "$STAMP"
) &
WRITER=$!

bash scripts/verify/run-debug.sh 16 diskio-live \
  --env METR_DEBUG_WINDOW_SCRIPT=disk@1 \
  --expect 'diskio r=[0-9]+ w=[0-9]+' --min 10 \
  --args -MetrDidPresentWelcome YES

wait "$WRITER" || fail "the writer exited non-zero"
WRITER=""

read -r start end < "$STAMP" || fail "the writer left no start / end stamp"
[[ "$start" =~ ^[0-9]+\.[0-9]+$ && "$end" =~ ^[0-9]+\.[0-9]+$ ]] || fail "unreadable writer stamp '$start $end'"

# A sample at time t reports the interval before t, so the burst shows up to a second after it ends.
max_before="$(awk -v s="$start" '$2 == "diskio" && $3 ~ /^r=/ && $1 < s { sub(/^w=/, "", $4); if ($4 + 0 > m) m = $4 + 0 } END { printf "%d", m }' "$LOG")"
max_during="$(awk -v s="$start" -v e="$end" '$2 == "diskio" && $3 ~ /^r=/ && $1 >= s + 1 && $1 <= e + 1.5 { sub(/^w=/, "", $4); if ($4 + 0 > m) m = $4 + 0 } END { printf "%d", m }' "$LOG")"

[ "$max_during" -ge 20000000 ] || fail "the write burst is not visible: max w=$max_during B/s during the writer (before: $max_before; LOG=$LOG)"
[ "$max_during" -gt "$max_before" ] || fail "the write rate during the burst ($max_during) is not above the rate before it ($max_before; LOG=$LOG)"

echo "DISKIO-LIVE OK max_w=$max_during"

#!/usr/bin/env bash
# Usage: scripts/verify/proc-diskio.sh
# PROC-04 accuracy: proves the per-process disk write rate the RUNNING Debug app measures follows
# a real writer, and that a root process (WindowServer, which comes from top and has no per-process
# I/O) says nothing instead of a fabricated zero. A python3 writer overwrites one 64 MiB file under
# $TMPDIR in 8 MiB chunks with an fsync after each and a short pause, so it writes about 16 MB/s
# (a few hundred MB in total, not gigabytes). The file is on the internal disk (preflight
# guarantees 2 GiB free), is only ever overwritten in place, and a trap deletes it and the writer.
#
# The app runs 12 s with the window opened on Processes (METR_DEBUG_WINDOW_SCRIPT, through
# run-debug.sh) and METR_DEBUG_PROBE_PIDS=<writer>,<WindowServer>. Fails unless the writer's
# probe lines show a maximum `dw=` of at least 5_000_000 B/s and every WindowServer probe line
# shows `dr=- dw=-`. Probe lines carry pids and numbers only.
# Prints "PROC-DISKIO OK max_dw=<B/s>" or "FAIL: <what>" with exit 1.
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

WS_PID="$(pgrep -x WindowServer | head -n 1 || true)"
[ -n "$WS_PID" ] || fail "WindowServer is not running"

mkdir -p "$METR_LOGS"
LOG="$METR_LOGS/proc-diskio.log"
FILE="$(mktemp "$TMP/metr-proc-diskio.XXXXXX")"
WRITER=""

cleanup() {
  if [ -n "$WRITER" ] && kill -0 "$WRITER" 2>/dev/null; then kill "$WRITER" 2>/dev/null || true; fi
  rm -f "$FILE"
  metr_kill || true
}
trap cleanup EXIT

python3 -I -c '
import os, sys, time
path, seconds = sys.argv[1], float(sys.argv[2])
chunk = os.urandom(8 * 1024 * 1024)
start = time.monotonic()
fd = os.open(path, os.O_WRONLY)
try:
    while time.monotonic() - start < seconds:
        os.lseek(fd, 0, os.SEEK_SET)
        for _ in range(8):  # 8 x 8 MiB = the 64 MiB file, overwritten in place
            os.write(fd, chunk)
            os.fsync(fd)
            time.sleep(0.5)  # about 16 MB/s, not as fast as the disk allows
finally:
    os.close(fd)
' "$FILE" 11 &
WRITER=$!
WRITER_PID="$WRITER"

bash scripts/verify/run-debug.sh 12 proc-diskio \
  --env "METR_DEBUG_PROBE_PIDS=$WRITER_PID,$WS_PID" \
  --env METR_DEBUG_WINDOW_SCRIPT=processes@0.5 \
  --expect "probe pid=$WRITER_PID mem=[0-9]+ cpu=[0-9.]+ dr=[0-9]+ dw=[0-9]+" --min 3 \
  --expect "probe pid=$WS_PID mem=[0-9]+ cpu=[0-9.]+ dr=- dw=-" --min 3 \
  --args -MetrDidPresentWelcome YES

wait "$WRITER" || fail "the writer exited non-zero"
WRITER=""

# A WindowServer probe line with a number in either disk field is a fabricated rate.
if grep -E "probe pid=$WS_PID " "$LOG" | grep -vqE 'dr=- dw=-$'; then
  fail "WindowServer shows a disk rate; macOS gives Metr none for system processes (LOG=$LOG)"
fi

max_dw="$(grep -E "probe pid=$WRITER_PID " "$LOG" | sed -nE 's/.* dw=([0-9]+)$/\1/p' | sort -n | tail -n 1)"
max_dw="${max_dw:-0}"
[ "$max_dw" -ge 5000000 ] || fail "the writer's disk write rate is not visible: max dw=$max_dw B/s (LOG=$LOG)"

echo "PROC-DISKIO OK max_dw=$max_dw"

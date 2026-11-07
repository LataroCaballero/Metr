#!/usr/bin/env bash
# Usage: scripts/verify/net-vs-netstat.sh
# NET-01 accuracy and the no-network promise (T-03-14). Runs the Debug app for 14 s with the
# Network section open, reads the summed Ibytes / Obytes of the en* link rows of `netstat -ib`
# before and after, and compares them with the bytes Metr logged (each logged rate times the
# time it covered). While Metr samples, a harness-made download (curl, never Metr) creates real
# traffic; when it fails the run falls back to ambient traffic and says so. While the app runs,
# `lsof` must show Metr holding no internet socket.
#
# The window closes at 12 s, and the Network section's session total ("net total down=<bytes>
# up=<bytes>", logged when the window closes and every fifth sample) is compared with the same netstat
# delta: Metr's own total must be within 15 % of it when netstat saw more than 5 MB downloaded.
#
# Tolerance: within 20 % when netstat saw more than 5 MB downloaded, else within 200 kB/s on
# average over Metr's sampled span.
#
# Prints "NO-SOCKETS OK", then "NET-VS-NETSTAT OK app=<B/s> netstat=<B/s>" (both over Metr's
# sampled span), or "FAIL: <what>" with exit 1. Needs the Debug app (scripts/build.sh debug).
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
# shellcheck source=../env.sh
source scripts/env.sh

fail() { echo "FAIL: $1"; exit 1; }

NAME="net-vs-netstat"
SECS=14
URL="https://proof.ovh.net/files/100Mb.dat"
LOG="$METR_LOGS/$NAME.log"
[ -d "$METR_APP_DEBUG" ] || fail "Debug app not found at $METR_APP_DEBUG (run scripts/build.sh debug)"
mkdir -p "$METR_LOGS"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; metr_kill || true' EXIT

# "<Ibytes> <Obytes>" summed over the en* <Link#> rows. Counted from the right, so a row with no
# hardware address (a different column count) still parses; a trailing "*" marks a down interface.
netstat_totals() {
  netstat -ib | awk '
    $3 ~ /^<Link#/ && $1 ~ /^en[0-9]+\*?$/ { i += $(NF-4); o += $(NF-1) }
    END { printf "%.0f %.0f\n", i, o }'
}
now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }

metr_kill
rm -f "$LOG"

read -r IN0 OUT0 <<<"$(netstat_totals)"
T0="$(now)"

bash scripts/verify/run-debug.sh "$SECS" "$NAME" \
  --env 'METR_DEBUG_WINDOW_SCRIPT=network@1;close@12' \
  --expect 'net down=[0-9]+ up=[0-9]+' --min 8 \
  --args -MetrDidPresentWelcome YES >"$TMP/run.out" 2>&1 &
RUN_PID=$!

# Wait for Metr to start sampling (the first "net" line), then give the baseline a moment.
for _ in $(seq 1 80); do
  grep -q ' net ' "$LOG" 2>/dev/null && break
  sleep 0.1
done
grep -q ' net ' "$LOG" 2>/dev/null || { wait "$RUN_PID" || true; cat "$TMP/run.out"; fail "Metr logged no network line within 8 s"; }
sleep 1.5

# Real traffic made by the harness: a download of at most 8 s.
(
  DL="$(curl -sf -o /dev/null --max-time 8 -w '%{size_download}' "$URL" 2>/dev/null || true)"
  case "$DL" in ''|*[!0-9]*|0) echo "NOTE: offline, ambient traffic only" ;; *) echo "NOTE: downloaded $DL bytes" ;; esac
) >"$TMP/curl.out" 2>&1 &
CURL_PID=$!

# Metr must hold no internet socket while the Network section samples.
sleep 3
PID="$(pgrep -x Metr | head -n 1 || true)"
[ -n "$PID" ] || fail "Metr is not running"
SOCKETS="$(lsof -a -p "$PID" -i 2>/dev/null || true)"
if [ -n "$SOCKETS" ]; then
  printf '%s\n' "$SOCKETS"
  fail "Metr holds a network socket"
fi
echo "NO-SOCKETS OK"

wait "$CURL_PID" || true
wait "$RUN_PID" || { cat "$TMP/run.out"; fail "run-debug failed"; }
cat "$TMP/curl.out"

T1="$(now)"
read -r IN1 OUT1 <<<"$(netstat_totals)"
[ -s "$LOG" ] || fail "no Metr log at $LOG"

# Bytes Metr logged: each rate times the interval it covered (log timestamps are seconds).
# A "net pending" line (the baseline) opens an interval and does not count itself.
read -r APP_IN APP_OUT SPAN COUNT <<<"$(awk '
  / net pending$/ { prev = $1; if (first == "") first = $1; next }
  / net down=[0-9]+ up=[0-9]+/ {
    d = $3; u = $4; sub(/^down=/, "", d); sub(/^up=/, "", u)
    if (prev != "") { dt = $1 - prev; si += d * dt; so += u * dt; n++; last = $1 }
    prev = $1; if (first == "") first = $1
  }
  END { printf "%.0f %.0f %.3f %d\n", si, so, (last == "" ? 0 : last - first), n }' "$LOG")"

[[ "$COUNT" =~ ^[0-9]+$ ]] && [ "$COUNT" -ge 8 ] || fail "too few net lines in $LOG (count=$COUNT)"
awk -v s="$SPAN" 'BEGIN { exit !(s > 0) }' || fail "Metr's sampled span is not positive (span=$SPAN)"

# The session total the Network section showed: the last "net total" line (the one the closing window logs).
TOTAL_LINE="$(grep -E ' net total down=[0-9]+ up=[0-9]+$' "$LOG" | tail -n 1 || true)"
[ -n "$TOTAL_LINE" ] || fail "Metr logged no 'net total' line (the Network section's session totals)"
TOTAL_DOWN="$(printf '%s' "$TOTAL_LINE" | sed -E 's/.* down=([0-9]+) up=([0-9]+)$/\1/')"
TOTAL_UP="$(printf '%s' "$TOTAL_LINE" | sed -E 's/.* down=([0-9]+) up=([0-9]+)$/\2/')"
[[ "$TOTAL_DOWN" =~ ^[0-9]+$ && "$TOTAL_UP" =~ ^[0-9]+$ ]] || fail "unreadable net total line: $TOTAL_LINE"

NS_IN=$(( IN1 - IN0 ))
NS_OUT=$(( OUT1 - OUT0 ))
ELAPSED="$(awk -v a="$T0" -v b="$T1" 'BEGIN { printf "%.3f", b - a }')"

APP_RATE="$(awk -v b="$APP_IN" -v s="$SPAN" 'BEGIN { printf "%.0f", b / s }')"
NS_RATE="$(awk -v b="$NS_IN" -v s="$SPAN" 'BEGIN { printf "%.0f", b / s }')"
echo "INFO: session_total_down=${TOTAL_DOWN} session_total_up=${TOTAL_UP}"
echo "INFO: elapsed=${ELAPSED}s span=${SPAN}s app_down=${APP_IN} netstat_down=${NS_IN} app_up=${APP_OUT} netstat_up=${NS_OUT}"

if [ "$NS_IN" -gt 5000000 ]; then
  awk -v a="$APP_IN" -v b="$NS_IN" 'BEGIN { d = a - b; if (d < 0) d = -d; exit !(d <= 0.20 * b) }' \
    || fail "download app=$APP_IN bytes netstat=$NS_IN bytes differ by more than 20 %"
else
  awk -v a="$APP_RATE" -v b="$NS_RATE" 'BEGIN { d = a - b; if (d < 0) d = -d; exit !(d <= 200000) }' \
    || fail "download app=$APP_RATE B/s netstat=$NS_RATE B/s differ by more than 200 kB/s"
fi

# The Network section's own session totals against netstat over the same run.
if [ "$NS_IN" -gt 5000000 ]; then
  awk -v a="$TOTAL_DOWN" -v b="$NS_IN" 'BEGIN { d = a - b; if (d < 0) d = -d; exit !(d <= 0.15 * b) }' \
    || fail "session total down=$TOTAL_DOWN bytes netstat=$NS_IN bytes differ by more than 15 %"
else
  awk -v a="$TOTAL_DOWN" -v b="$NS_IN" 'BEGIN { d = a - b; if (d < 0) d = -d; exit !(d <= 2400000) }' \
    || fail "session total down=$TOTAL_DOWN bytes netstat=$NS_IN bytes differ by more than 2.4 MB"
fi

echo "NET-VS-NETSTAT OK app=$APP_RATE netstat=$NS_RATE total=$TOTAL_DOWN"

#!/usr/bin/env bash
# Memory-stability soaks for FND-03.
#
#   soak.sh --quick [SECONDS]        Debug app at 20x idle cadence (default 60 s): no growth in leaks
#                                    attributed to Metr frames, at most QUICK_SOAK_GROWTH_MB_MAX growth.
#   soak.sh --release --hours N      Release app at the real idle cadence, in the foreground: footprint
#                                    slope and leaks delta. Writes the MEASURED_SOAK_* lines of budget.env.
#   soak.sh --start-24h              Starts the 24 h soak detached (survives the shell), output in
#                                    $METR_LOGS/soak-24h.out, pid in $METR_LOGS/soak.pid.
#   soak.sh --status                 SOAK OK|FAIL <details>, SOAK RUNNING ..., SOAK INTERRUPTED or
#                                    SOAK NOT STARTED.
#
# Every script that calls metr_kill ends a running soak: run nothing else while it runs.
# The whole script is wrapped in functions and ends with `main "$@"; exit`, so bash has parsed it
# completely before running: editing this file during a 24 h soak cannot corrupt the running copy.

SOAK_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

soak_setup() {
  set -euo pipefail
  cd "$(git rev-parse --show-toplevel)"
  # shellcheck source=../env.sh
  source scripts/env.sh
  # shellcheck source=lib.sh
  source scripts/perf/lib.sh
  BUDGET="$METR_ROOT/scripts/perf/budget.env"
  # shellcheck source=budget.env
  source "$BUDGET"
  mkdir -p "$METR_LOGS"
  SOAK_OUT="$METR_LOGS/soak-24h.out"
  SOAK_PID_FILE="$METR_LOGS/soak.pid"
  SOAK_CURRENT="$METR_LOGS/soak.current"
}

fail() { echo "$1"; exit 1; }

# Prints "<total leaks> <leaks attributed to Metr frames>" for a pid.
# A bare SwiftUI status-item app already reports ~287 framework leaks (RESEARCH Pitfall 5), so only
# lines inside the leak listing that mention a Metr module or symbol are attributed to Metr. Only
# deltas are ever asserted, never "0 leaks". `leaks` exits 1 when it finds any leak, which is normal.
leak_stats() {
  local out total metr
  out="$(leaks "$1" 2>/dev/null || true)"
  total="$(printf '%s\n' "$out" | sed -nE 's/^Process [0-9]+: ([0-9]+) leaks? for.*/\1/p' | head -n 1)"
  [ -n "$total" ] || return 1
  metr="$(printf '%s\n' "$out" | awk '
    /^Process [0-9]+: [0-9]+ leaks? for/ { on = 1; next }
    /^Binary Images:/ { on = 0 }
    on && /(Metr|MetrCore|MetrSystem|MetrRender)/ { n++ }
    END { print n + 0 }')"
  printf '%s %s\n' "$total" "$metr"
}

soak_quick() {
  local secs="${1:-60}"
  [ -d "$METR_APP_DEBUG" ] || fail "FAIL: Debug app not found at $METR_APP_DEBUG (run scripts/build.sh debug)"
  local bin
  bin="$(metr_rusage_bin)"

  metr_kill
  trap 'metr_kill || true' EXIT
  # 20x the idle cadence (CPU and memory every 0.1 s, disk every 3 s): 60 s covers about 20
  # minutes of real idle ticks. MallocStackLogging gives the leaks report its stacks.
  open -g -n --env METR_DEBUG_CADENCE_SCALE=0.05 --env MallocStackLogging=1 \
    "$METR_APP_DEBUG" --args -MetrDidPresentWelcome YES
  sleep 10
  local pid
  pid="$(metr_pid "$METR_APP_DEBUG")"
  [ -n "$pid" ] || fail "SOAK FAIL Metr did not start"
  [ "$(metr_count)" = "1" ] || fail "SOAK FAIL expected exactly one running Metr, found $(metr_count)"

  local start_stats metr_start
  start_stats="$(leak_stats "$pid")" || fail "SOAK FAIL leaks could not read pid $pid"
  metr_start="${start_stats#* }"

  local first="" last="" now end snap
  end=$(( $(date +%s) + secs ))
  while :; do
    snap="$("$bin" "$pid" --snapshot)" || fail "SOAK FAIL Metr exited during the soak"
    last="$(printf '%s\n' "$snap" | sed -E 's/.*footprint_mb=([0-9.]+).*/\1/')"
    [ -n "$first" ] || first="$last"
    now="$(date +%s)"
    [ "$now" -lt "$end" ] || break
    sleep 5
  done

  local end_stats metr_end growth
  end_stats="$(leak_stats "$pid")" || fail "SOAK FAIL leaks could not read pid $pid at the end"
  metr_end="${end_stats#* }"
  growth="$(awk -v a="$first" -v b="$last" 'BEGIN { printf "%.1f", b - a }')"

  if [ "$metr_end" -gt "$metr_start" ]; then
    fail "SOAK FAIL metr_leaks_grew growth_mb=$growth metr_leaks_start=$metr_start metr_leaks_end=$metr_end"
  fi
  if [ "$(metr_gt "$growth" "$QUICK_SOAK_GROWTH_MB_MAX")" = "1" ]; then
    fail "SOAK FAIL footprint_growth growth_mb=$growth max=$QUICK_SOAK_GROWTH_MB_MAX metr_leaks_start=$metr_start metr_leaks_end=$metr_end"
  fi
  echo "SOAK OK growth_mb=$growth metr_leaks_start=$metr_start metr_leaks_end=$metr_end"
}

# Least-squares footprint slope (MB per hour) of a "<epoch>,<mb>" CSV.
csv_slope() {
  awk -F, '
    NR == 1 { t0 = $1 }
    { x = ($1 - t0) / 3600; y = $2; n++; sx += x; sy += y; sxy += x * y; sxx += x * x }
    END {
      d = n * sxx - sx * sx
      if (n < 2 || d == 0) { printf "0.000"; exit }
      printf "%.3f", (n * sxy - sx * sy) / d
    }' "$1"
}

write_soak_result() { # RESULT SLOPE HOURS LEAKS_DELTA
  budget_set "$BUDGET" \
    MEASURED_SOAK_RESULT "$1" \
    MEASURED_SOAK_SLOPE_MB_PER_HOUR "$2" \
    MEASURED_SOAK_HOURS "$3" \
    MEASURED_SOAK_LEAKS_DELTA "$4" \
    MEASURED_SOAK_AT "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

soak_release() {
  local hours="${1:?hours}"
  [ -d "$METR_APP_RELEASE" ] || fail "SOAK FAIL Release app not found at $METR_APP_RELEASE"
  local bin
  bin="$(metr_rusage_bin)"

  metr_kill
  SOAK_APP_PID=""
  trap '[ -z "$SOAK_APP_PID" ] || kill "$SOAK_APP_PID" 2>/dev/null || true' EXIT
  open -g -n "$METR_APP_RELEASE" --args -MetrDidPresentWelcome YES
  sleep 10
  local pid
  pid="$(metr_pid "$METR_APP_RELEASE")"
  [ -n "$pid" ] || fail "SOAK FAIL app did not start"
  [ "$(metr_count)" = "1" ] || fail "SOAK FAIL expected exactly one running Metr, found $(metr_count)"
  SOAK_APP_PID="$pid"

  local sig cdhash
  sig="$(codesign -dvvv "$METR_APP_RELEASE" 2>&1 || true)"
  cdhash="$(printf '%s\n' "$sig" | sed -n 's/^CDHash=//p' | head -n 1)"
  echo "SOAK START pid=$pid cdhash=$cdhash at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local csv="$METR_LOGS/soak-$(date +%Y%m%d-%H%M%S).csv"
  : > "$csv"
  printf '%s\n' "$csv" > "$SOAK_CURRENT"

  local snap mb t0 duration
  duration="$(awk -v h="$hours" 'BEGIN { printf "%d", h * 3600 }')"
  append_row() {
    snap="$("$bin" "$pid" --snapshot 2>/dev/null)" || return 1
    mb="$(printf '%s\n' "$snap" | sed -E 's/.*footprint_mb=([0-9.]+).*/\1/')"
    printf '%s,%s\n' "$(date +%s)" "$mb" >> "$csv"
  }
  append_row || fail "SOAK FAIL app exited slope_mb_per_hour=0.000 hours=0.00 leaks_delta=n/a"
  t0="$(date +%s)"

  local start_stats leaks_start
  start_stats="$(leak_stats "$pid")" || fail "SOAK FAIL leaks could not read pid $pid"
  leaks_start="${start_stats%% *}"

  local now remaining nap exited=0
  while :; do
    now="$(date +%s)"
    remaining=$(( t0 + duration - now ))
    [ "$remaining" -gt 0 ] || break
    nap=60
    [ "$remaining" -ge "$nap" ] || nap="$remaining"
    sleep "$nap"
    if ! kill -0 "$pid" 2>/dev/null || ! append_row; then
      exited=1
      break
    fi
  done

  local slope elapsed_h
  slope="$(csv_slope "$csv")"
  elapsed_h="$(awk -F, 'NR == 1 { a = $1 } { b = $1 } END { printf "%.2f", (b - a) / 3600 }' "$csv")"

  if [ "$exited" = "1" ]; then
    write_soak_result FAIL "$slope" "$elapsed_h" "n/a"
    fail "SOAK FAIL app exited slope_mb_per_hour=$slope hours=$elapsed_h leaks_delta=n/a"
  fi

  local end_stats leaks_end leaks_delta
  end_stats="$(leak_stats "$pid")" || {
    write_soak_result FAIL "$slope" "$elapsed_h" "n/a"
    fail "SOAK FAIL leaks could not read pid $pid at the end slope_mb_per_hour=$slope hours=$elapsed_h leaks_delta=n/a"
  }
  leaks_end="${end_stats%% *}"
  leaks_delta=$(( leaks_end - leaks_start ))

  local reason=""
  [ "$(metr_gt "$hours" "$elapsed_h")" = "0" ] || reason="short_run"
  [ "$(metr_gt "$slope" "$FOOTPRINT_SLOPE_MB_PER_HOUR_MAX")" = "0" ] || reason="${reason:+$reason,}slope_too_high"
  [ "$leaks_delta" -le 0 ] || reason="${reason:+$reason,}leaks_grew"

  if [ -n "$reason" ]; then
    write_soak_result FAIL "$slope" "$elapsed_h" "$leaks_delta"
    fail "SOAK FAIL $reason slope_mb_per_hour=$slope hours=$elapsed_h leaks_delta=$leaks_delta"
  fi
  write_soak_result OK "$slope" "$elapsed_h" "$leaks_delta"
  echo "SOAK OK slope_mb_per_hour=$slope hours=$elapsed_h leaks_delta=$leaks_delta"
}

soak_alive() {
  [ -f "$SOAK_PID_FILE" ] || return 1
  local pid
  pid="$(cat "$SOAK_PID_FILE")"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || return 1
  pgrep -f 'soak.sh --release --hours' | grep -qx "$pid"
}

soak_start_24h() {
  if soak_alive; then
    fail "SOAK ALREADY RUNNING pid=$(cat "$SOAK_PID_FILE") (see: bash scripts/perf/soak.sh --status)"
  fi
  rm -f "$SOAK_CURRENT" "$SOAK_PID_FILE"
  : > "$SOAK_OUT"
  # A new session (setsid) detached from this shell, so the soak outlives the caller. nohup also
  # ignores SIGHUP. Output goes to the .out file only.
  perl -MPOSIX -e 'POSIX::setsid(); open(STDIN, "<", "/dev/null"); exec @ARGV' \
    nohup bash "$SOAK_SCRIPT" --release --hours 24 >> "$SOAK_OUT" 2>&1 &
  echo "$!" > "$SOAK_PID_FILE"

  local waited=0
  while [ "$waited" -lt 45 ]; do
    if [ -f "$SOAK_CURRENT" ] && [ -s "$(cat "$SOAK_CURRENT")" ]; then
      echo "SOAK STARTED out=$SOAK_OUT eta=$(date -u -v+24H +%Y-%m-%dT%H:%M:%SZ) pid=$(cat "$SOAK_PID_FILE") csv=$(cat "$SOAK_CURRENT")"
      return 0
    fi
    sleep 1
    waited=$(( waited + 1 ))
  done
  fail "SOAK NOT STARTED no CSV row after 45 s (see $SOAK_OUT)"
}

soak_status() {
  local last=""
  [ ! -f "$SOAK_OUT" ] || last="$(grep -E '^SOAK (OK|FAIL)' "$SOAK_OUT" | tail -n 1 || true)"
  if [ -n "$last" ]; then
    echo "$last"
    case "$last" in "SOAK OK"*) return 0 ;; *) return 1 ;; esac
  fi
  if soak_alive; then
    local csv rows elapsed_h
    csv="$(cat "$SOAK_CURRENT" 2>/dev/null || true)"
    rows=0; elapsed_h="0.00"
    if [ -n "$csv" ] && [ -f "$csv" ]; then
      rows="$(wc -l < "$csv" | tr -d ' ')"
      elapsed_h="$(awk -F, 'NR == 1 { a = $1 } { b = $1 } END { printf "%.2f", (b - a) / 3600 }' "$csv")"
    fi
    echo "SOAK RUNNING elapsed_h=$elapsed_h rows=$rows"
    return 0
  fi
  if [ -f "$SOAK_OUT" ]; then
    echo "SOAK INTERRUPTED"
  else
    echo "SOAK NOT STARTED"
  fi
  return 1
}

usage() {
  echo "usage: soak.sh --quick [SECONDS] | --release --hours N | --start-24h | --status" >&2
  exit 2
}

main() {
  soak_setup
  case "${1:-}" in
    --quick) soak_quick "${2:-60}" ;;
    --release)
      [ "${2:-}" = "--hours" ] && [ -n "${3:-}" ] || usage
      soak_release "$3" ;;
    --start-24h) soak_start_24h ;;
    --status) soak_status ;;
    *) usage ;;
  esac
}

main "$@"; exit $?

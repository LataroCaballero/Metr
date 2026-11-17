#!/usr/bin/env bash
# Usage: scripts/release/measure-footprint.sh VERSION --shipped APP --relhooks APP
# Measures Metr's own cost on two named builds and writes docs/footprint.env, the single source of every
# number in the README footprint table (D-19, D-24). Nothing here is typed by hand and no threshold is
# ever written or read for writing.
#   VERSION     the version the numbers are for, e.g. 1.0.0 or 1.0.0-rc.1 (it is printed in the README)
#   --shipped   the staged release Metr.app (scripts/release/build-release.sh output): idle row
#   --relhooks  the optimized build with the measurement hooks (scripts/build.sh relhooks): panel and
#               window rows (the real release build has no way to open the panel or window by script)
#
# RUN TIME: about 12 minutes (measure.sh 300 s, panel-cost.sh 60 s, window-cost.sh cpu 60 s and cycles
# 10, each with launch and settle time). A foreground tool call stops at 10 minutes, so callers start
# this script detached and read its log:
#   bash scripts/release/measure-footprint.sh 1.0.0 --shipped APP --relhooks APP > "$METR_LOGS/footprint-1.0.0.out" 2>&1
#
# Rows: idle = measure.sh on the shipped app; panel = panel-cost.sh (Metr plus its top child, both parts
# kept); window = window-cost.sh cpu (Metr's own process, no top child); cycles = window-cost.sh cycles
# (exit 3 KNOWN-FAILURE is accepted and its growth_mb kept; any other failure stops the run).
# The file is KEY=VALUE, one per line, values unquoted and possibly with spaces: read it with grep, awk or
# python, never `source` it.
# Prints "FOOTPRINT OK version=<v>" or "FAIL: <reason>" with exit 1.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
# shellcheck source=../env.sh
source scripts/env.sh
# shellcheck source=../perf/lib.sh
source scripts/perf/lib.sh

fail() { echo "FAIL: $1" >&2; exit 1; }
usage() { echo "usage: scripts/release/measure-footprint.sh VERSION --shipped APP --relhooks APP" >&2; exit 2; }

[ "$#" -ge 1 ] || usage
VERSION="$1"; shift
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$ ]] || { echo "FAIL: version '$VERSION' is not <major>.<minor>.<patch> with an optional -rc.<n>" >&2; exit 2; }
SHIPPED=""; RELHOOKS=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --shipped)  [ "$#" -ge 2 ] || usage; SHIPPED="$2"; shift 2 ;;
    --relhooks) [ "$#" -ge 2 ] || usage; RELHOOKS="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[ -d "$SHIPPED" ] || fail "shipped app not found: $SHIPPED"
[ -d "$RELHOOKS" ] || fail "relhooks app not found: $RELHOOKS"

OUT="$METR_ROOT/docs/footprint.env"
mkdir -p "$METR_ROOT/docs"
LOGS="$METR_LOGS/footprint-$VERSION"
mkdir -p "$LOGS"

# Value of KEY=<number> inside a measurement line, validated as a plain number (fail closed).
field() {
  local line="$1" key="$2" value
  value="$(printf '%s\n' "$line" | sed -nE "s/.*[[:space:]]${key}=([0-9.]+).*/\1/p" | head -n 1)"
  metr_is_number "$value" || fail "could not read $key from: $line"
  printf '%s\n' "$value"
}

# The machine and the shipped build (who measured what, on what).
HW="$(system_profiler SPHardwareDataType 2>/dev/null)"
MODEL="$(printf '%s\n' "$HW" | sed -nE 's/^ *Model Name: *//p' | head -n 1)"
CHIP="$(printf '%s\n' "$HW" | sed -nE 's/^ *Chip: *//p' | head -n 1)"
[ -n "$MODEL" ] && [ -n "$CHIP" ] || fail "could not read the Mac model and chip from system_profiler"
MACOS="$(sw_vers -productVersion)"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$SHIPPED/Contents/Info.plist")"
[[ "$BUILD" =~ ^[0-9]+$ ]] || fail "shipped app has no numeric CFBundleVersion ('$BUILD')"
CDHASH="$(codesign -dvvv "$SHIPPED" 2>&1 | sed -n 's/^CDHash=//p' | head -n 1)"
[ -n "$CDHASH" ] || fail "could not read the shipped app's CDHash"

metr_kill

echo "FOOTPRINT idle: measure.sh 300 on $SHIPPED"
IDLE_OUT="$(METR_APP_RELEASE="$SHIPPED" bash scripts/perf/measure.sh 300 2>&1 | tee "$LOGS/idle.out")" \
  || fail "measure.sh failed (see $LOGS/idle.out)"
printf '%s\n' "$IDLE_OUT" | tail -n 8
printf '%s\n' "$IDLE_OUT" | grep -q '^BUDGET PASS ' || fail "no BUDGET PASS line from measure.sh"
IDLE_LINE="$(printf '%s\n' "$IDLE_OUT" | grep '^RUSAGE ' | tail -n 1)"
IDLE_CPU="$(field "$IDLE_LINE" cpu_pct)"
IDLE_MB="$(field "$IDLE_LINE" footprint_mb)"
IDLE_WAKE="$(field "$IDLE_LINE" wakeups_per_s)"

echo "FOOTPRINT panel: panel-cost.sh 60 on $RELHOOKS"
PANEL_OUT="$(PANEL_COST_APP="$RELHOOKS" bash scripts/perf/panel-cost.sh 60 2>&1 | tee "$LOGS/panel.out")" \
  || fail "panel-cost.sh failed (see $LOGS/panel.out)"
PANEL_LINE="$(printf '%s\n' "$PANEL_OUT" | grep '^PANEL-COST ' | tail -n 1)"
[ -n "$PANEL_LINE" ] || fail "no PANEL-COST line"
PANEL_METR="$(field "$PANEL_LINE" metr_cpu)"
PANEL_TOP="$(field "$PANEL_LINE" top_cpu)"
PANEL_TOTAL="$(field "$PANEL_LINE" total)"
PANEL_MB="$(field "$PANEL_LINE" metr_footprint)"
PANEL_WAKE="$(field "$PANEL_LINE" metr_wakeups)"

echo "FOOTPRINT window: window-cost.sh cpu 60 on $RELHOOKS"
WIN_OUT="$(WINDOW_COST_APP="$RELHOOKS" bash scripts/perf/window-cost.sh cpu 60 2>&1 | tee "$LOGS/window.out")" \
  || fail "window-cost.sh cpu failed (see $LOGS/window.out)"
WIN_LINE="$(printf '%s\n' "$WIN_OUT" | grep '^WINDOW-COST section=cpu ' | tail -n 1)"
[ -n "$WIN_LINE" ] || fail "no WINDOW-COST section=cpu line"
WIN_CPU="$(field "$WIN_LINE" metr_cpu)"
WIN_MB="$(field "$WIN_LINE" metr_footprint)"
WIN_WAKE="$(field "$WIN_LINE" metr_wakeups)"

echo "FOOTPRINT cycles: window-cost.sh cycles 10 on $RELHOOKS (exit 3 is the known failure)"
set +e
CYC_OUT="$(WINDOW_COST_APP="$RELHOOKS" bash scripts/perf/window-cost.sh cycles 10 2>&1 | tee "$LOGS/cycles.out"; exit "${PIPESTATUS[0]}")"
CYC_STATUS=$?
set -e
case "$CYC_STATUS" in
  0|3) ;;
  *) fail "window-cost.sh cycles exited $CYC_STATUS (see $LOGS/cycles.out)" ;;
esac
CYC_LINE="$(printf '%s\n' "$CYC_OUT" | grep '^WINDOW-COST cycles=' | tail -n 1)"
[ -n "$CYC_LINE" ] || fail "no WINDOW-COST cycles line"
CYC_N="$(printf '%s\n' "$CYC_LINE" | sed -nE 's/^WINDOW-COST cycles=([0-9]+) .*/\1/p')"
[[ "$CYC_N" =~ ^[0-9]+$ ]] || fail "could not read the cycle count from: $CYC_LINE"
CYC_GROWTH="$(field "$CYC_LINE" growth_mb)"

TMP="$(mktemp "$METR_ROOT/docs/.footprint.XXXXXX")"
cat > "$TMP" <<EOF
# Generated by scripts/release/measure-footprint.sh. Do not edit by hand and do not source this file.
# Every number in the README footprint tables comes from here (scripts/release/readme-footprint.sh).
FOOTPRINT_VERSION=$VERSION
FOOTPRINT_BUILD=$BUILD
FOOTPRINT_SHIPPED_CDHASH=$CDHASH
FOOTPRINT_MAC=$MODEL ($CHIP)
FOOTPRINT_MACOS=$MACOS
FOOTPRINT_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
IDLE_CPU_PCT=$IDLE_CPU
IDLE_MEMORY_MB=$IDLE_MB
IDLE_WAKEUPS=$IDLE_WAKE
PANEL_CPU_PCT=$PANEL_TOTAL
PANEL_METR_CPU_PCT=$PANEL_METR
PANEL_TOP_CPU_PCT=$PANEL_TOP
PANEL_MEMORY_MB=$PANEL_MB
PANEL_WAKEUPS=$PANEL_WAKE
WINDOW_CPU_PCT=$WIN_CPU
WINDOW_MEMORY_MB=$WIN_MB
WINDOW_WAKEUPS=$WIN_WAKE
WINDOW_CYCLES_GROWTH_MB=$CYC_GROWTH
WINDOW_CYCLES_N=$CYC_N
EOF
chmod 644 "$TMP"
mv "$TMP" "$OUT"
metr_kill || true
echo "FOOTPRINT OK version=$VERSION"

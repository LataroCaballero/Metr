#!/usr/bin/env bash
# Usage: scripts/verify/memory-vs-system.sh
# MEM-01 accuracy: builds the dev-only metr-probe, reads one memory sample, and compares it with
# vm_stat, memory_pressure and sysctl taken immediately after.
# Prints "MEMORY-VS-SYSTEM OK ..." or "FAIL: <what>" with exit 1.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
# shellcheck source=../env.sh
source scripts/env.sh

fail() { echo "FAIL: $1"; exit 1; }

mkdir -p "$METR_SPM" "$METR_LOGS"
swift build -c release --product metr-probe --package-path Packages/MetrKit --scratch-path "$METR_SPM" \
  > "$METR_LOGS/memory-vs-system-build.log" 2>&1 || { cat "$METR_LOGS/memory-vs-system-build.log"; fail "swift build metr-probe"; }
BIN="$(swift build -c release --package-path Packages/MetrKit --scratch-path "$METR_SPM" --show-bin-path)/metr-probe"
[ -x "$BIN" ] || fail "metr-probe not found at $BIN"

PROBE="$("$BIN" memory)" || fail "metr-probe memory exited non-zero"

# Immediately read the system values.
VMSTAT="$(vm_stat)"
MP_PCT="$(memory_pressure | tail -n 1 | sed -E 's/.*: ([0-9]+)%.*/\1/')"
SYS_PRESSURE="$(sysctl -n kern.memorystatus_vm_pressure_level)"
SYS_MEMSIZE="$(sysctl -n hw.memsize)"
SYS_PAGESIZE="$(sysctl -n hw.pagesize)"
SWAP_LINE="$(sysctl -n vm.swapusage)"

field() { echo "$PROBE" | tr ' ' '\n' | sed -n "s/^$1=//p"; }
P_USED="$(field used)"; P_TOTAL="$(field total)"; P_SWAP="$(field swap)"
P_FREE="$(field freePercent)"; P_PRESSURE="$(field pressure)"; P_PAGE="$(field pageSize)"

vm_pages() { echo "$VMSTAT" | grep -E "^$1:" | sed -E 's/[^0-9]*([0-9]+)\.?$/\1/'; }
VM_PAGE="$(echo "$VMSTAT" | head -n 1 | sed -E 's/.*page size of ([0-9]+) bytes.*/\1/')"
VM_ANON="$(vm_pages 'Anonymous pages')"
VM_PURG="$(vm_pages 'Pages purgeable')"
VM_WIRED="$(vm_pages 'Pages wired down')"
VM_COMP="$(vm_pages 'Pages occupied by compressor')"
for v in "$P_USED" "$P_TOTAL" "$P_SWAP" "$P_FREE" "$P_PRESSURE" "$P_PAGE" "$VM_PAGE" "$VM_ANON" "$VM_PURG" "$VM_WIRED" "$VM_COMP" "$MP_PCT"; do
  [[ "$v" =~ ^[0-9]+$ ]] || fail "could not parse a value (probe='$PROBE')"
done

VM_USED=$(( (VM_ANON - VM_PURG + VM_WIRED + VM_COMP) * VM_PAGE ))

# swap used, in bytes, from "used = X.XXM" (megabytes, MiB)
SWAP_USED_MB="$(echo "$SWAP_LINE" | sed -E 's/.*used = ([0-9.]+)M.*/\1/')"
SWAP_TOTAL_MB="$(echo "$SWAP_LINE" | sed -E 's/.*total = ([0-9.]+)M.*/\1/')"
SYS_SWAP="$(awk -v m="$SWAP_USED_MB" 'BEGIN { printf "%.0f", m * 1048576 }')"
SWAP_TOTAL="$(awk -v m="$SWAP_TOTAL_MB" 'BEGIN { printf "%.0f", m * 1048576 }')"

[ "$P_PAGE" = "$SYS_PAGESIZE" ] || fail "pageSize probe=$P_PAGE hw.pagesize=$SYS_PAGESIZE"
[ "$P_TOTAL" = "$SYS_MEMSIZE" ] || fail "total probe=$P_TOTAL hw.memsize=$SYS_MEMSIZE"

awk -v a="$P_USED" -v b="$VM_USED" -v t="$P_TOTAL" 'BEGIN { d = a - b; if (d < 0) d = -d; exit !(d / t <= 0.02) }' \
  || fail "used probe=$P_USED vm_stat=$VM_USED differ by more than 2% of total"

awk -v a="$P_FREE" -v b="$MP_PCT" 'BEGIN { d = a - b; if (d < 0) d = -d; exit !(d <= 3) }' \
  || fail "freePercent probe=$P_FREE memory_pressure=$MP_PCT differ by more than 3 points"

[ "$P_PRESSURE" = "$SYS_PRESSURE" ] || fail "pressure probe=$P_PRESSURE sysctl=$SYS_PRESSURE"

awk -v a="$P_SWAP" -v b="$SYS_SWAP" -v t="$SWAP_TOTAL" \
  'BEGIN { d = a - b; if (d < 0) d = -d; tol = t * 0.01; if (tol < 67108864) tol = 67108864; exit !(d <= tol) }' \
  || fail "swap probe=$P_SWAP vm.swapusage=$SYS_SWAP differ by more than max(1% of $SWAP_TOTAL, 64 MiB)"

echo "MEMORY-VS-SYSTEM OK pageSize=$P_PAGE/$SYS_PAGESIZE total=$P_TOTAL/$SYS_MEMSIZE used=$P_USED/$VM_USED free%=$P_FREE/$MP_PCT pressure=$P_PRESSURE/$SYS_PRESSURE swap=$P_SWAP/$SYS_SWAP"

#!/usr/bin/env bash
# Usage: scripts/verify/volumes-vs-diskutil.sh
# Compares the volume list the RUNNING Debug app logs with what diskutil and df say, so the Disk
# section's rows can be trusted (DISK-01, D-17). It runs the app 8 s with the window opened on Disk
# (METR_DEBUG_WINDOW_SCRIPT=disk@1;close@7, through run-debug.sh) and then:
#   1. counts the rows diskutil implies: "/" and every /Volumes/* mount point that is not a symlink,
#      read with `diskutil info -plist`, skipping disk images (BusProtocol "Disk Image"), network
#      mounts (not local in `mount`) and Time Machine volumes (a Backups.backupdb root or a name
#      ending in ".timemachine", RESEARCH Open Question 4), then counting the distinct
#      ParentWholeDisk values (one row per APFS container). The last logged `volumes n=` must match;
#   2. checks that the startup row's free bytes are within 1 % of the same run's `diskfree=`;
#   3. when exactly one external row exists, checks its free bytes are within 1 % of `df -k`
#      available x 1024 for that mount (an exFAT drive reports 0 "important usage" capacity, so this
#      is the false-zero check).
# Reads only: it never writes to, mounts or ejects any volume.
# Prints "VOLUMES-VS-DISKUTIL OK rows=<n>" or "FAIL: <what>" with exit 1.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
# shellcheck source=../env.sh
source scripts/env.sh

fail() { echo "FAIL: $1"; exit 1; }

bash scripts/verify/run-debug.sh 8 volumes-diskutil \
  --env 'METR_DEBUG_WINDOW_SCRIPT=disk@1;close@7' \
  --expect 'volumes n=[1-9]' \
  --args -MetrDidPresentWelcome YES >/dev/null
LOG="$METR_LOGS/volumes-diskutil.log"

# One line per expected row: "<wholeDisk> <internal 0|1> <mount>", already de-duplicated by whole disk.
EXPECTED_FILE="$(mktemp "${TMPDIR:-/tmp}/metr-volumes-expected.XXXXXX")"
trap 'rm -f "$EXPECTED_FILE"' EXIT
python3 -I - >"$EXPECTED_FILE" <<'PY'
import os, plistlib, subprocess

def run(args):
    return subprocess.run(args, capture_output=True, check=True).stdout

local_mounts = set()
for line in run(["mount"]).decode("utf-8", "replace").splitlines():
    if " on " not in line or " (" not in line:
        continue
    mount_point = line.split(" on ", 1)[1].rsplit(" (", 1)[0]
    flags = line.rsplit(" (", 1)[1]
    if "local" in flags.split(", "):
        local_mounts.add(mount_point)

mounts = ["/"]
if os.path.isdir("/Volumes"):
    for name in sorted(os.listdir("/Volumes")):
        path = os.path.join("/Volumes", name)
        if os.path.islink(path) or not os.path.isdir(path):
            continue
        mounts.append(path)

seen = {}
for mount in mounts:
    if mount not in local_mounts:
        continue
    try:
        info = plistlib.loads(run(["diskutil", "info", "-plist", mount]))
    except subprocess.CalledProcessError:
        continue
    if info.get("BusProtocol") in ("Disk Image", "Virtual Interface") or info.get("VirtualOrPhysical") == "Virtual":
        continue
    name = info.get("VolumeName") or ""
    if name.endswith(".timemachine") or os.path.isdir(os.path.join(mount, "Backups.backupdb")):
        continue
    whole = info.get("ParentWholeDisk") or info.get("DeviceIdentifier") or mount
    # The root volume names its container's row; otherwise the first mount seen does.
    if whole not in seen or mount == "/":
        seen[whole] = (1 if info.get("Internal") else 0, mount)
for whole, (internal, mount) in seen.items():
    print(whole, internal, mount)
PY
EXPECTED="$(cat "$EXPECTED_FILE")"

[ -n "$EXPECTED" ] || fail "diskutil implies no volume rows at all"
expected_rows="$(printf '%s\n' "$EXPECTED" | wc -l | tr -d ' ')"

logged_rows="$(grep -Eo 'volumes n=[0-9]+' "$LOG" | tail -n 1 | cut -d= -f2 || true)"
[ -n "$logged_rows" ] || fail "no 'volumes n=' line in $LOG"
[ "$logged_rows" = "$expected_rows" ] || fail "the app logged $logged_rows volume rows, diskutil implies $expected_rows"

# The last logged list: the `volume role=...` lines that follow the last `volumes n=` line.
LAST_LIST="$(awk '/volumes n=/ { block = "" } /volume role=/ { block = block $0 "\n" } END { printf "%s", block }' "$LOG")"

within_one_percent() { # a b -> exit 0 when |a-b| <= 1 % of the larger
  python3 -I -c 'import sys; a, b = int(sys.argv[1]), int(sys.argv[2]); sys.exit(0 if abs(a - b) <= 0.01 * max(a, b, 1) else 1)' "$1" "$2"
}

startup_free="$(printf '%s' "$LAST_LIST" | grep 'role=startup' | head -n 1 | sed -E 's/.* free=([0-9]+).*/\1/' || true)"
[[ "$startup_free" =~ ^[0-9]+$ ]] || fail "the startup row logged no free figure ($LOG)"
diskfree="$(grep -Eo 'diskfree=[0-9]+' "$LOG" | tail -n 1 | cut -d= -f2 || true)"
[[ "$diskfree" =~ ^[0-9]+$ ]] || fail "no numeric diskfree= value in $LOG"
within_one_percent "$startup_free" "$diskfree" \
  || fail "the startup row's free ($startup_free) differs from diskfree= ($diskfree) by more than 1 %"

external_rows="$(printf '%s' "$LAST_LIST" | grep -c 'role=external' || true)"
note=""
if [ "$external_rows" = "1" ]; then
  mount_point="$(printf '%s\n' "$EXPECTED" | awk '$2 == 0 { sub(/^[^ ]+ [01] /, ""); print }')"
  if [ -n "$mount_point" ] && [ "$(printf '%s\n' "$mount_point" | wc -l | tr -d ' ')" = "1" ]; then
    external_free="$(printf '%s' "$LAST_LIST" | grep 'role=external' | sed -E 's/.* free=([0-9]+).*/\1/')"
    [[ "$external_free" =~ ^[0-9]+$ ]] || fail "the external row logged no free figure ($LOG)"
    df_avail_kib="$(df -k "$mount_point" | awk 'NR == 2 { print $4 }')"
    [[ "$df_avail_kib" =~ ^[0-9]+$ ]] || fail "could not read df available for the external mount"
    df_free=$(( df_avail_kib * 1024 ))
    [ "$external_free" -gt 0 ] || [ "$df_free" -eq 0 ] || fail "the external row shows 0 free but df reports $df_free bytes (false zero)"
    within_one_percent "$external_free" "$df_free" \
      || fail "the external row's free ($external_free) differs from df ($df_free) by more than 1 %"
    note=" external_free=$external_free df_free=$df_free"
  fi
fi

echo "VOLUMES-VS-DISKUTIL OK rows=$logged_rows startup_free=$startup_free diskfree=$diskfree${note}"

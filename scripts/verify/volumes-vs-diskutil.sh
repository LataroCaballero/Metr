#!/usr/bin/env bash
# Usage: scripts/verify/volumes-vs-diskutil.sh [--mount]
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
#
# With --mount it checks the refresh trigger instead (DISK-02): it creates a 20 MB throwaway APFS
# disk image under $METR_BUILD_ROOT, runs the Debug app 12 s with the window on Disk, attaches the
# image about 4 s in and detaches it about 8 s in, and requires `volumes refresh reason=mount` and
# `volumes refresh reason=unmount` in the log with the logged row count never changing (disk images
# are excluded from the list, D-17). It touches only its own image: the device it attached is the
# only one it ever detaches, and a trap detaches and deletes the image on every exit.
# Prints "VOLUMES-VS-DISKUTIL OK mount=1 unmount=1" or "FAIL: <what>" with exit 1.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
# shellcheck source=../env.sh
source scripts/env.sh

fail() { echo "FAIL: $1"; exit 1; }

if [ "${1:-}" = "--mount" ]; then
  IMAGE="$METR_BUILD_ROOT/metr-mount-check.dmg"
  DEVICE=""
  cleanup() {
    if [ -n "$DEVICE" ]; then hdiutil detach "$DEVICE" -force >/dev/null 2>&1 || true; fi
    rm -f "$IMAGE"
  }
  trap cleanup EXIT
  mkdir -p "$METR_BUILD_ROOT" "$METR_LOGS"
  rm -f "$IMAGE"
  hdiutil create -size 20m -fs APFS -volname MetrTestVol "$IMAGE" >/dev/null || fail "could not create the test disk image"

  bash scripts/verify/run-debug.sh 12 volumes-mount \
    --env 'METR_DEBUG_WINDOW_SCRIPT=disk@1;close@11' \
    --expect 'volumes n=[1-9]' \
    --expect 'volumes refresh reason=mount' \
    --expect 'volumes refresh reason=unmount' \
    --args -MetrDidPresentWelcome YES >"$METR_LOGS/volumes-mount.out" 2>&1 &
  APP_RUN=$!
  sleep 4
  ATTACH_OUT="$(hdiutil attach -noverify -noautoopen "$IMAGE")" || fail "could not attach the test disk image"
  DEVICE="$(printf '%s\n' "$ATTACH_OUT" | head -n 1 | awk '{ print $1 }')"
  [[ "$DEVICE" =~ ^/dev/disk[0-9]+$ ]] || { DEVICE=""; fail "could not read the attached device from hdiutil"; }
  sleep 4
  diskutil unmount "$(printf '%s\n' "$ATTACH_OUT" | grep -Eo '/Volumes/.*$' | head -n 1)" >/dev/null 2>&1 || true
  sleep 1
  hdiutil detach "$DEVICE" >/dev/null 2>&1 || hdiutil detach "$DEVICE" -force >/dev/null 2>&1 || fail "could not detach the test disk image"
  DEVICE=""
  wait "$APP_RUN" || { cat "$METR_LOGS/volumes-mount.out"; fail "the app run failed (see above)"; }

  LOG="$METR_LOGS/volumes-mount.log"
  distinct_counts="$(grep -Eo 'volumes n=[0-9]+' "$LOG" | sort -u | wc -l | tr -d ' ')"
  [ "$distinct_counts" = "1" ] || fail "the logged row count changed while a disk image came and went ($distinct_counts distinct values, LOG=$LOG)"
  echo "VOLUMES-VS-DISKUTIL OK mount=1 unmount=1"
  exit 0
fi

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

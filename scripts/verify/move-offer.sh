#!/usr/bin/env bash
# Usage: scripts/verify/move-offer.sh
# D-13: the Move to Applications offer. Runs the Debug app with the move hooks (never touching
# /Applications; METR_DEBUG_MOVE_DESTINATION points at a scratch directory) and checks:
#   decisions: the logged decision for a launch from a mounted read-only disk image, from an ordinary
#              folder and from the DerivedData build path;
#   move:      a real move from the read-only image: the copy keeps the CDHash and a valid signature,
#              exactly one Metr runs afterwards, from the destination, and the image-launched pid is gone;
#   replace:   an older same-identifier copy goes to the Trash (of a scratch volume, gone when it detaches);
#   newer:     a newer copy is left untouched and not offered over;
#   foreign:   a copy with another bundle identifier is left untouched and the move fails;
#   notnow:    a decline is remembered for the same version and class;
#   present:   `present` and `present-failure` show the real alerts and move nothing.
#
# Prints "MOVE-OFFER OK decisions=3 move=1 replace=1 newer=1 foreign=1 notnow=1 present=2" or "FAIL: <what>". Always launches with -MetrDidPresentWelcome YES,
# and the scripted Not Now record goes to the throwaway ".script" preferences suite, so the owner's
# domain stays untouched. Cleanup (always): quits Metr, detaches the test image, removes only this
# script's own mktemp directory and deletes the suite.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
# shellcheck source=../env.sh
source scripts/env.sh

SUITE="io.github.latarocaballero.Metr.script"
WORK=""
MOUNT=""
DEST_MOUNT=""

fail() { echo "FAIL: $1"; exit 1; }

cleanup() {
  metr_kill || true
  if [ -n "$MOUNT" ] && [ -d "$MOUNT" ]; then
    hdiutil detach -quiet "$MOUNT" 2>/dev/null || hdiutil detach -quiet -force "$MOUNT" 2>/dev/null || true
  fi
  if [ -n "$DEST_MOUNT" ] && [ -d "$DEST_MOUNT" ]; then
    hdiutil detach -quiet "$DEST_MOUNT" 2>/dev/null || hdiutil detach -quiet -force "$DEST_MOUNT" 2>/dev/null || true
  fi
  if [ -n "$WORK" ] && [ -d "$WORK" ]; then
    rm -rf "$WORK"
  fi
  defaults delete "$SUITE" >/dev/null 2>&1 || true
}
trap cleanup EXIT

[ -d "$METR_APP_DEBUG" ] || fail "Debug app not found at $METR_APP_DEBUG (run scripts/build.sh debug)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/metr-move-XXXXXX")"
mkdir -p "$METR_LOGS"
defaults delete "$SUITE" >/dev/null 2>&1 || true

# --- helpers -----------------------------------------------------------------------------------

# launch APP LOG [KEY=VALUE]...: starts the app in the background with the log hook and the move env.
launch() {
  local app="$1" log="$2"; shift 2
  local args=(-g -n --env "METR_DEBUG_LOG=$log")
  local e
  for e in "$@"; do args+=(--env "$e"); done
  : > "$log"
  open "${args[@]}" "$app" --args -MetrDidPresentWelcome YES
}

# wait_log LOG REGEX SECONDS: succeeds as soon as a line matches.
wait_log() {
  local log="$1" re="$2" secs="$3" i
  for i in $(seq 1 $((secs * 5))); do
    grep -Eq -- "$re" "$log" 2>/dev/null && return 0
    sleep 0.2
  done
  return 1
}

# probe NAME APP [KEY=VALUE]...: runs one probe launch and prints its log path once the decision is logged.
probe() {
  local name="$1" app="$2"; shift 2
  local log="$METR_LOGS/move-offer-$name.log"
  metr_kill
  launch "$app" "$log" METR_DEBUG_MOVE_PROBE=1 "$@"
  wait_log "$log" '^.*move-offer class=' 10 || fail "no move-offer line for '$name' (LOG=$log)"
  metr_kill
  echo "$log"
}

expect_line() {
  local log="$1" re="$2" what="$3"
  grep -Eq -- "$re" "$log" || fail "$what: no line matching '$re' (LOG=$log)"
}

# --- fixtures ----------------------------------------------------------------------------------

WORK="$(cd "$WORK" && pwd -P)"
mkdir -p "$WORK/src" "$WORK/dest-decisions" "$WORK/folder"
ditto "$METR_APP_DEBUG" "$WORK/src/Metr.app"
ditto "$METR_APP_DEBUG" "$WORK/folder/Metr.app"
hdiutil create -quiet -srcfolder "$WORK/src" -volname MetrMoveTest -format UDZO -ov "$WORK/MetrMoveTest.dmg" \
  || fail "hdiutil create failed"
ATTACH_OUT="$(hdiutil attach -readonly -nobrowse "$WORK/MetrMoveTest.dmg")" || fail "hdiutil attach failed"
MOUNT="$(printf '%s\n' "$ATTACH_OUT" | awk -F'\t' '/\/Volumes\//{ gsub(/[[:space:]]+$/, "", $NF); print $NF; exit }')"
[ -n "$MOUNT" ] && [ -d "$MOUNT/Metr.app" ] || fail "the test image did not mount with Metr.app"

# A writable scratch volume holds the move destinations. A replaced copy goes to the Trash of the
# volume it sat on, so on this volume the trashed item disappears when the image is detached: nothing
# is left in the owner's ~/.Trash (which a shell cannot clean anyway).
hdiutil create -quiet -size 64m -fs APFS -volname MetrMoveDest -type SPARSE "$WORK/dest.sparseimage" \
  || fail "hdiutil create (destination volume) failed"
DEST_OUT="$(hdiutil attach -nobrowse "$WORK/dest.sparseimage")" || fail "hdiutil attach (destination volume) failed"
DEST_MOUNT="$(printf '%s\n' "$DEST_OUT" | awk -F'\t' '/\/Volumes\//{ gsub(/[[:space:]]+$/, "", $NF); print $NF; exit }')"
[ -n "$DEST_MOUNT" ] && [ -d "$DEST_MOUNT" ] || fail "the destination volume did not mount"
DEST_MOUNT="$(cd "$DEST_MOUNT" && pwd -P)"

# --- decisions ---------------------------------------------------------------------------------

log="$(probe dmg "$MOUNT/Metr.app" "METR_DEBUG_MOVE_DESTINATION=$WORK/dest-decisions")"
expect_line "$log" 'move-offer class=diskImage decision=offer replace=nothing' "launch from the mounted image"

log="$(probe folder "$WORK/folder/Metr.app" "METR_DEBUG_MOVE_DESTINATION=$WORK/dest-decisions")"
expect_line "$log" 'move-offer class=elsewhere decision=offer replace=nothing' "launch from a plain folder"

log="$(probe development "$METR_APP_DEBUG" "METR_DEBUG_MOVE_DESTINATION=$WORK/dest-decisions")"
expect_line "$log" 'move-offer class=development decision=skip replace=nothing reason=development' "launch from the DerivedData build"

[ -z "$(ls -A "$WORK/dest-decisions")" ] || fail "a decision-only run wrote into the destination"

# --- helpers for the move scenarios ------------------------------------------------------------

cdhash() { codesign -dvvv "$1" 2>&1 | sed -n 's/^CDHash=//p'; }
mtimes() { stat -f '%m' "$1" "$1/Contents/Info.plist"; }

# new_dest NAME [VERSION|id:IDENTIFIER]: a scratch destination, optionally holding a modified copy.
new_dest() {
  local dir="$DEST_MOUNT/dest-$1"
  mkdir -p "$dir"
  case "${2:-}" in
    "") ;;
    id:*)
      ditto "$WORK/src/Metr.app" "$dir/Metr.app"
      plutil -replace CFBundleIdentifier -string "${2#id:}" "$dir/Metr.app/Contents/Info.plist" ;;
    *)
      ditto "$WORK/src/Metr.app" "$dir/Metr.app"
      plutil -replace CFBundleVersion -string "$2" "$dir/Metr.app/Contents/Info.plist" ;;
  esac
  echo "$dir"
}

# run_move NAME DEST CONFIRM: launches the image copy with the destination and the confirm hook.
run_move() {
  local name="$1" dest="$2" confirm="$3"
  local log="$METR_LOGS/move-offer-$name.log"
  metr_kill
  launch "$MOUNT/Metr.app" "$log" METR_DEBUG_MOVE_PROBE=1 "METR_DEBUG_MOVE_DESTINATION=$dest" "METR_DEBUG_MOVE_CONFIRM=$confirm"
  echo "$log"
}

# --- move --------------------------------------------------------------------------------------

DEST="$(new_dest move)"
log="$(run_move move "$DEST" move)"
OLD_PID=""
for _ in $(seq 1 50); do OLD_PID="$(pgrep -x Metr | head -n 1 || true)"; [ -n "$OLD_PID" ] && break; sleep 0.2; done
[ -n "$OLD_PID" ] || fail "the image copy did not start"
wait_log "$log" 'move result=moved relaunch=1' 10 || fail "move: no 'move result=moved relaunch=1' line (LOG=$log)"
# Exactly one Metr must remain, and it is the new one.
NEW_PID=""
for _ in $(seq 1 75); do
  count="$(pgrep -x Metr | wc -l | tr -d ' ')"
  NEW_PID="$(pgrep -x Metr | head -n 1 || true)"
  if [ "$count" = "1" ] && [ -n "$NEW_PID" ] && [ "$NEW_PID" != "$OLD_PID" ]; then break; fi
  NEW_PID=""
  sleep 0.2
done
[ -n "$NEW_PID" ] || fail "move: not exactly one new Metr process after the move (pgrep: $(pgrep -x Metr | tr '\n' ' '))"
kill -0 "$OLD_PID" 2>/dev/null && fail "move: the image-launched process is still running"
NEW_EXE="$(ps -p "$NEW_PID" -o comm= | sed 's/^[[:space:]]*//')"
case "$NEW_EXE" in
  "$DEST"/Metr.app/Contents/MacOS/*) ;;
  *) fail "move: the running copy is '$NEW_EXE', not inside the destination" ;;
esac
[ -d "$DEST/Metr.app" ] || fail "move: no Metr.app at the destination"
[ "$(cdhash "$DEST/Metr.app")" = "$(cdhash "$MOUNT/Metr.app")" ] && [ -n "$(cdhash "$MOUNT/Metr.app")" ] \
  || fail "move: the copy's CDHash differs from the source's"
codesign --verify --deep --strict "$DEST/Metr.app" 2>/dev/null || fail "move: the copy fails codesign --verify --deep --strict"
metr_kill

# --- replace -----------------------------------------------------------------------------------

DEST="$(new_dest replace 0)"
log="$(run_move replace "$DEST" move)"
wait_log "$log" 'move result=moved relaunch=1' 10 || fail "replace: no 'move result=moved' line (LOG=$log)"
expect_line "$log" 'move-offer class=diskImage decision=offer replace=trash' "replace"
TRASHED="$(sed -n 's/.*move trashed=//p' "$log" | head -n 1)"
[ -n "$TRASHED" ] || fail "replace: no 'move trashed=' line (LOG=$log)"
sleep 1
metr_kill
[ -e "$TRASHED" ] || fail "replace: the trashed item is not at '$TRASHED'"
[ "$(plutil -extract CFBundleVersion raw -o - "$TRASHED/Contents/Info.plist")" = "0" ] \
  || fail "replace: the trashed item is not the pre-placed old copy"
[ "$(plutil -extract CFBundleVersion raw -o - "$DEST/Metr.app/Contents/Info.plist")" \
  = "$(plutil -extract CFBundleVersion raw -o - "$WORK/src/Metr.app/Contents/Info.plist")" ] \
  || fail "replace: the new copy is not in place"
# The trashed item sits in the scratch volume's Trash and goes with the volume; nothing to delete here.
case "$TRASHED" in
  "$DEST_MOUNT"/.Trashes/*) ;;
  *) fail "replace: '$TRASHED' is not in the scratch volume's Trash (it would be left in a real Trash)" ;;
esac

# --- newer -------------------------------------------------------------------------------------

DEST="$(new_dest newer 9999)"
before="$(mtimes "$DEST/Metr.app")"
log="$(run_move newer "$DEST" move)"
wait_log "$log" 'move-offer class=' 10 || fail "newer: no decision line (LOG=$log)"
sleep 2
metr_kill
expect_line "$log" 'decision=skip replace=nothing reason=newer-installed' "newer"
grep -q 'move result=\|move trashed=' "$log" && fail "newer: Metr acted on a newer installed copy (LOG=$log)"
[ "$(mtimes "$DEST/Metr.app")" = "$before" ] || fail "newer: the newer installed copy was modified"

# --- foreign -----------------------------------------------------------------------------------

DEST="$(new_dest foreign id:com.example.NotMetr)"
before="$(mtimes "$DEST/Metr.app")"
log="$(run_move foreign "$DEST" move)"
wait_log "$log" 'move result=failed relaunch=0' 10 || fail "foreign: no 'move result=failed' line (LOG=$log)"
sleep 1
metr_kill
expect_line "$log" 'decision=offer replace=refuse' "foreign"
grep -q 'move trashed=' "$log" && fail "foreign: Metr trashed a foreign item (LOG=$log)"
[ "$(mtimes "$DEST/Metr.app")" = "$before" ] || fail "foreign: the foreign item was modified"
[ "$(plutil -extract CFBundleIdentifier raw -o - "$DEST/Metr.app/Contents/Info.plist")" = "com.example.NotMetr" ] \
  || fail "foreign: the foreign item was replaced"

# --- not now -----------------------------------------------------------------------------------

defaults delete "$SUITE" >/dev/null 2>&1 || true
DEST="$(new_dest notnow)"
log="$(run_move notnow "$DEST" notnow)"
wait_log "$log" 'move declined class=diskImage' 10 || fail "notnow: no 'move declined class=diskImage' line (LOG=$log)"
sleep 1
metr_kill
log="$(probe notnow-again "$MOUNT/Metr.app" "METR_DEBUG_MOVE_DESTINATION=$DEST")"
expect_line "$log" 'move-offer class=diskImage decision=skip replace=nothing reason=declined' "notnow: the next launch"
[ -z "$(ls -A "$DEST")" ] || fail "notnow: something was written to the destination"

# --- present: the real alerts ------------------------------------------------------------------

present_check() {
  local confirm="$1" kind="$2"
  local dir="$DEST_MOUNT/dest-present-$kind"
  mkdir -p "$dir"
  local plog="$METR_LOGS/move-offer-present-$kind.log"
  metr_kill
  launch "$WORK/folder/Metr.app" "$plog" "METR_DEBUG_MOVE_DESTINATION=$dir" "METR_DEBUG_MOVE_CONFIRM=$confirm"
  wait_log "$plog" "move alert shown kind=$kind" 6 || fail "present: no 'move alert shown kind=$kind' line (LOG=$plog)"
  sleep 1
  pgrep -x Metr >/dev/null || fail "present: Metr is not waiting in the alert for kind=$kind"
  metr_kill
  [ -z "$(ls -A "$dir")" ] || fail "present: the destination is not empty after kind=$kind"
}
present_check present offer
present_check present-failure failure

echo "MOVE-OFFER OK decisions=3 move=1 replace=1 newer=1 foreign=1 notnow=1 present=2"

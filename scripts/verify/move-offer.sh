#!/usr/bin/env bash
# Usage: scripts/verify/move-offer.sh
# D-13: the Move to Applications offer. Runs the Debug app with the move hooks (never touching
# /Applications) and checks the logged decision for a launch from a mounted read-only disk image, from
# an ordinary folder and from the DerivedData build path.
#
# Prints "MOVE-OFFER OK decisions=3" or "FAIL: <what>". Always launches with -MetrDidPresentWelcome YES,
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

fail() { echo "FAIL: $1"; exit 1; }

cleanup() {
  metr_kill || true
  if [ -n "$MOUNT" ] && [ -d "$MOUNT" ]; then
    hdiutil detach -quiet "$MOUNT" 2>/dev/null || hdiutil detach -quiet -force "$MOUNT" 2>/dev/null || true
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

mkdir -p "$WORK/src" "$WORK/dest-decisions" "$WORK/folder"
ditto "$METR_APP_DEBUG" "$WORK/src/Metr.app"
ditto "$METR_APP_DEBUG" "$WORK/folder/Metr.app"
hdiutil create -quiet -srcfolder "$WORK/src" -volname MetrMoveTest -format UDZO -ov "$WORK/MetrMoveTest.dmg" \
  || fail "hdiutil create failed"
ATTACH_OUT="$(hdiutil attach -readonly -nobrowse "$WORK/MetrMoveTest.dmg")" || fail "hdiutil attach failed"
MOUNT="$(printf '%s\n' "$ATTACH_OUT" | awk -F'\t' '/\/Volumes\//{ gsub(/[[:space:]]+$/, "", $NF); print $NF; exit }')"
[ -n "$MOUNT" ] && [ -d "$MOUNT/Metr.app" ] || fail "the test image did not mount with Metr.app"

# --- decisions ---------------------------------------------------------------------------------

log="$(probe dmg "$MOUNT/Metr.app" "METR_DEBUG_MOVE_DESTINATION=$WORK/dest-decisions")"
expect_line "$log" 'move-offer class=diskImage decision=offer replace=nothing' "launch from the mounted image"

log="$(probe folder "$WORK/folder/Metr.app" "METR_DEBUG_MOVE_DESTINATION=$WORK/dest-decisions")"
expect_line "$log" 'move-offer class=elsewhere decision=offer replace=nothing' "launch from a plain folder"

log="$(probe development "$METR_APP_DEBUG" "METR_DEBUG_MOVE_DESTINATION=$WORK/dest-decisions")"
expect_line "$log" 'move-offer class=development decision=skip replace=nothing reason=development' "launch from the DerivedData build"

[ -z "$(ls -A "$WORK/dest-decisions")" ] || fail "a decision-only run wrote into the destination"

echo "MOVE-OFFER OK decisions=3"

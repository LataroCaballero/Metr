#!/usr/bin/env bash
# Usage: scripts/verify/dmg.sh DMG APP
# Gate for the release image (D-12 look, D-21 tool, T-04-18). Mounts the DMG read-only, then proves:
#   - Metr.app, an Applications symlink to /Applications, the background image and the volume icon
#   - the inner app passes codesign --verify --deep --strict and has the CDHash of APP (the staged app)
#   - the window layout read back from the image's own .DS_Store with ds_store (the venv of make-dmg.sh):
#     Iloc Metr.app (168, 180), Iloc Applications (432, 180), window 600 x 400, toolbar, status bar,
#     path bar and sidebar hidden, icon size 128, a background alias that points at the image's background
#   - the DMG itself verifies and reports Signature=adhoc
#   - the committed background.tiff holds a 600 x 400 and a 1200 x 800 representation, and the copy
#     inside the image is that file
#   - informational only: a copy of the DMG gets a Safari-style quarantine attribute and spctl assesses it
#     (expected: rejected, which is why the README documents Open Anyway; RESEARCH Pitfall 8). Printed as the
#     spctl line (rejected or accepted), it never fails the gate
# The trap always detaches. Prints "DMG OK layout=600x400 icons=2 inner_cdhash=<h> signature=adhoc".
set -euo pipefail

fail() { echo "FAIL: $1" >&2; exit 1; }
[ "$#" -eq 2 ] || { echo "usage: scripts/verify/dmg.sh DMG APP" >&2; exit 2; }
DMG="$1"; APP="$2"
[ -f "$DMG" ] || fail "DMG not found: $DMG"
[ -d "$APP" ] || fail "app not found: $APP"

cd "$(git rev-parse --show-toplevel)"
# shellcheck source=../env.sh
source scripts/env.sh
VENV_PY="$METR_BUILD_ROOT/venv-dmg/bin/python"
[ -x "$VENV_PY" ] || fail "no venv at $METR_BUILD_ROOT/venv-dmg (run scripts/release/make-dmg.sh first)"
TIFF="$METR_ROOT/scripts/release/dmg/background.tiff"
[ -f "$TIFF" ] || fail "missing $TIFF"

MNT="$(mktemp -d)"
ATTACHED=0
cleanup() {
  if [ "$ATTACHED" = "1" ]; then
    hdiutil detach "$MNT" -quiet >/dev/null 2>&1 || hdiutil detach "$MNT" -force -quiet >/dev/null 2>&1 || true
  fi
  rmdir "$MNT" 2>/dev/null || true
}
trap cleanup EXIT

cdhash_of() { codesign -dvvv "$1" 2>&1 | sed -n 's/^CDHash=//p' | head -n 1; }

# The DMG's own signature, read before anything mounts.
dmg_sig="$(codesign -dv "$DMG" 2>&1)"
codesign --verify --strict "$DMG" 2>/dev/null || fail "codesign --verify --strict failed on the DMG"
printf '%s\n' "$dmg_sig" | grep -q '^Signature=adhoc$' || fail "the DMG is not Signature=adhoc"

# The committed background has both representations.
tiff_info="$(tiffutil -info "$TIFF" 2>&1)"
printf '%s\n' "$tiff_info" | grep -q 'Image Width: 600 Image Length: 400' || fail "background.tiff has no 600 x 400 representation"
printf '%s\n' "$tiff_info" | grep -q 'Image Width: 1200 Image Length: 800' || fail "background.tiff has no 1200 x 800 representation"

hdiutil attach -readonly -nobrowse -noverify -mountpoint "$MNT" "$DMG" >/dev/null || fail "could not attach the DMG"
ATTACHED=1

# Contents.
[ -d "$MNT/Metr.app" ] || fail "Metr.app is missing from the DMG"
[ -L "$MNT/Applications" ] || fail "Applications is not a symlink"
[ "$(readlink "$MNT/Applications")" = "/Applications" ] || fail "Applications does not point to /Applications"
[ -f "$MNT/.VolumeIcon.icns" ] || fail "the volume icon .VolumeIcon.icns is missing"
[ -f "$MNT/.DS_Store" ] || fail "the layout file .DS_Store is missing"
# dmgbuild keeps the background at the image's top level as a dot file (not in a .background folder).
BG="$MNT/.background.tiff"
[ -f "$BG" ] || fail "the background image .background.tiff is missing"
cmp -s "$BG" "$TIFF" || fail "the background inside the DMG is not the committed background.tiff"
diskutil info "$MNT" | grep -qE 'Volume Name:[[:space:]]+Metr$' || fail "the volume is not named Metr"

# The inner app is the app that was verified.
codesign --verify --deep --strict "$MNT/Metr.app" 2>/dev/null || fail "codesign --verify --deep --strict failed on the app inside the DMG"
INNER="$(cdhash_of "$MNT/Metr.app")"
OUTER="$(cdhash_of "$APP")"
[[ "$INNER" =~ ^[0-9a-f]{40}$ ]] || fail "could not read the CDHash of the app inside the DMG"
[ "$INNER" = "$OUTER" ] || fail "inner CDHash $INNER differs from the staged app $OUTER"

# The layout, read back from the file.
"$VENV_PY" -I - "$MNT/.DS_Store" <<'PY' || exit 1
import sys
from ds_store import DSStore
from mac_alias import Alias

def fail(message):
    print("FAIL: " + message, file=sys.stderr)
    sys.exit(1)

entries = {}
with DSStore.open(sys.argv[1], "r") as store:
    for e in store:
        entries[(e.filename, e.code)] = e.value

if entries.get((".", b"bwsp")) is None or entries.get((".", b"icvp")) is None:
    fail(".DS_Store has no window (bwsp) or icon view (icvp) record")
bwsp = entries[(".", b"bwsp")]
icvp = entries[(".", b"icvp")]

if bwsp.get("WindowBounds") != "{{200, 200}, {600, 400}}":
    fail("window bounds are %r, expected a 600 x 400 window" % bwsp.get("WindowBounds"))
for key in ("ShowToolbar", "ShowStatusBar", "ShowPathbar", "ShowSidebar", "ShowTabView"):
    if bwsp.get(key) is not False:
        fail("%s is not hidden in .DS_Store (%r)" % (key, bwsp.get(key)))
if icvp.get("iconSize") != 128.0:
    fail("icon size is %r, expected 128" % icvp.get("iconSize"))
alias_bytes = icvp.get("backgroundImageAlias")
if not alias_bytes or icvp.get("backgroundType") != 2:
    fail("no background image alias in .DS_Store")
alias = Alias.from_bytes(alias_bytes)
if alias.target.filename != ".background.tiff":
    fail("the background alias points at %r" % alias.target.filename)
for name, expected in (("Metr.app", (168, 180)), ("Applications", (432, 180))):
    got = entries.get((name, b"Iloc"))
    if got != expected:
        fail("Iloc of %s is %r, expected %r" % (name, got, expected))
PY

# Gatekeeper on a quarantined copy (informational; the original is never touched).
GK_DIR="$(mktemp -d)"
cp -- "$DMG" "$GK_DIR/copy.dmg"
xattr -w com.apple.quarantine "0083;$(printf '%x' "$(date +%s)");Safari;" "$GK_DIR/copy.dmg" 2>/dev/null || true
if spctl --assess --type open --context context:primary-signature "$GK_DIR/copy.dmg" >/dev/null 2>&1; then
  GK="accepted"
else
  GK="rejected"
fi
rm -rf -- "$GK_DIR"
echo "DMG GATEKEEPER spctl=$GK"

SIG="$(printf '%s\n' "$dmg_sig" | sed -n 's/^Signature=//p')"
echo "DMG OK layout=600x400 icons=2 inner_cdhash=$INNER signature=$SIG"

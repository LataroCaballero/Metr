#!/usr/bin/env bash
# Usage: scripts/release/make-dmg.sh APP VERSION OUTDIR
# Builds OUTDIR/Metr-VERSION.dmg headless from the staged, re-signed APP with dmgbuild (D-21), signs the
# image ad hoc (D-23, not notarized) and writes OUTDIR/Metr-VERSION.dmg.sha256 (file name only).
#   - the Python environment lives in $METR_BUILD_ROOT/venv-dmg, never in the repository (T-04-16)
#   - dmg-requirements.txt pins dmgbuild 1.6.7, ds_store 1.3.3 and mac_alias 2.2.3 with every sha256;
#     pip runs with --require-hashes --no-deps, so any substituted file is refused; the version is
#     asserted after the install
#   - interpreter: $METR_DMG_PYTHON, else the first of python3.14 ... python3.10, python3 that is >= 3.10
# On any failure the partial DMG and checksum are removed (no partial release asset).
# Prints "DMG BUILT path=<dmg> sha256=<hex>". Exit 2 on bad arguments, 1 on any failure.
set -euo pipefail

fail() { echo "FAIL: $1" >&2; exit 1; }
usage() { echo "usage: scripts/release/make-dmg.sh APP VERSION OUTDIR" >&2; exit 2; }

[ "$#" -eq 3 ] || usage
APP="$1"; VERSION="$2"; OUTDIR="$3"

VERSION_RE='^[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$'
[[ "$VERSION" =~ $VERSION_RE ]] || { echo "FAIL: version '$VERSION' is not <major>.<minor>.<patch> with an optional -rc.<n>" >&2; exit 2; }
[ -d "$APP" ] || fail "app not found: $APP"
[ "$(basename "$APP")" = "Metr.app" ] || fail "the app must be named Metr.app"

cd "$(git rev-parse --show-toplevel)"
# shellcheck source=../env.sh
source scripts/env.sh

APP="$(cd "$APP" && pwd -P)"
mkdir -p "$OUTDIR"
OUTDIR="$(cd "$OUTDIR" && pwd -P)"
DMG="$OUTDIR/Metr-$VERSION.dmg"
SHA_FILE="$DMG.sha256"
BACKGROUND="$METR_ROOT/scripts/release/dmg/background.tiff"
SETTINGS="$METR_ROOT/scripts/release/dmg-settings.py"
REQUIREMENTS="$METR_ROOT/scripts/release/dmg-requirements.txt"
VOLICON="$APP/Contents/Resources/AppIcon.icns"
VENV="$METR_BUILD_ROOT/venv-dmg"

SUCCESS=0
cleanup() {
  if [ "$SUCCESS" != "1" ]; then
    rm -f -- "$DMG" "$SHA_FILE"
  fi
}
trap cleanup EXIT

for f in "$BACKGROUND" "$SETTINGS" "$REQUIREMENTS" "$VOLICON"; do
  [ -f "$f" ] || fail "missing input: $f"
done
rm -f -- "$DMG" "$SHA_FILE"

# 1. Interpreter (3.10 or newer; dmgbuild needs it).
py_ok() {
  "$1" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' >/dev/null 2>&1
}
PY=""
if [ -n "${METR_DMG_PYTHON:-}" ]; then
  PY="$METR_DMG_PYTHON"
  command -v "$PY" >/dev/null 2>&1 || fail "METR_DMG_PYTHON=$PY is not executable"
  py_ok "$PY" || fail "METR_DMG_PYTHON=$PY is older than Python 3.10"
else
  for candidate in python3.14 python3.13 python3.12 python3.11 python3.10 python3; do
    if command -v "$candidate" >/dev/null 2>&1 && py_ok "$candidate"; then PY="$candidate"; break; fi
  done
  [ -n "$PY" ] || fail "no Python 3.10 or newer found (set METR_DMG_PYTHON)"
fi
PY_VERSION="$("$PY" -c 'import platform; print(platform.python_version())')"
echo "DMG python=$PY version=$PY_VERSION venv=$VENV" >&2

# 2. Hash-pinned install into the venv outside the repository.
if [ ! -x "$VENV/bin/python" ]; then
  mkdir -p "$METR_BUILD_ROOT"
  "$PY" -m venv "$VENV" >&2
fi
"$VENV/bin/python" -m pip install --disable-pip-version-check --no-input --quiet \
  --require-hashes --no-deps -r "$REQUIREMENTS" >&2 \
  || fail "pip refused the hash-pinned install"
for pin in dmgbuild:1.6.7 ds_store:1.3.3 mac_alias:2.2.3; do
  pkg="${pin%%:*}"; want="${pin##*:}"
  have="$("$VENV/bin/python" -m pip show "$pkg" 2>/dev/null | sed -n 's/^Version: //p')"
  [ "$have" = "$want" ] || fail "$pkg is $have in the venv, expected $want"
done

# 3. Build the image: window, icons, background and volume icon come from dmg-settings.py.
"$VENV/bin/dmgbuild" -s "$SETTINGS" \
  -D "app=$APP" -D "background=$BACKGROUND" -D "volicon=$VOLICON" \
  Metr "$DMG" >&2 || fail "dmgbuild failed"
[ -f "$DMG" ] || fail "dmgbuild produced no image"

# 4. Ad-hoc signature on the image (D-23). Not notarized.
codesign --force --sign - "$DMG" >&2 || fail "codesign failed on the DMG"
codesign --verify --strict "$DMG" >&2 || fail "codesign --verify failed on the DMG"

# 5. Checksum, file name only so `shasum -a 256 -c` works from the download folder.
( cd "$OUTDIR" && shasum -a 256 "Metr-$VERSION.dmg" > "Metr-$VERSION.dmg.sha256" )
SHA="$(cut -d' ' -f1 "$SHA_FILE")"
[[ "$SHA" =~ ^[0-9a-f]{64}$ ]] || fail "could not compute the SHA-256"

SUCCESS=1
echo "DMG BUILT path=$DMG sha256=$SHA"

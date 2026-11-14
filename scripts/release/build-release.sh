#!/usr/bin/env bash
# Usage: scripts/release/build-release.sh TAG [--out DIR]
# Turns a release tag into a Release Metr.app that is staged, ad-hoc re-signed last and verified.
#   TAG      v<major>.<minor>.<patch> with an optional -rc.<n>; the numeric part must equal the
#            project's MARKETING_VERSION in both target configurations (D-10)
#   --out    directory the DMG step (04-08) writes to; accepted and recorded here, not used
# CFBundleShortVersionString is the numeric part of the tag (an rc ships the same string), and
# CFBundleVersion is `git rev-list --count HEAD`: monotonic along history, so a newer download
# replaces an older install, and identical locally and on CI (the checkout needs full history).
# Runs unchanged on the owner's Mac and in CI mode (METR_CI=1).
# Prints "RELEASE-BUILD OK version=<v> build=<n> cdhash=<h> app=<path>".
# Exit 2 on a bad tag or bad arguments, 1 on any failed gate.
set -euo pipefail

fail() { echo "FAIL: $1" >&2; exit 1; }
usage() { echo "usage: scripts/release/build-release.sh TAG [--out DIR]" >&2; exit 2; }

[ "$#" -ge 1 ] || usage
TAG="$1"; shift
OUT_DIR=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --out) [ "$#" -ge 2 ] || usage; OUT_DIR="$2"; shift 2 ;;
    *) usage ;;
  esac
done

# 1. The tag is validated before any other use: it is an externally chosen string (T-04-13).
TAG_RE='^v[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$'
if ! [[ "$TAG" =~ $TAG_RE ]]; then
  echo "FAIL: tag '$TAG' is not v<major>.<minor>.<patch> with an optional -rc.<n>" >&2
  exit 2
fi
VERSION="${TAG#v}"
BASE="${VERSION%%-rc.*}"

cd "$(git rev-parse --show-toplevel)"
# shellcheck source=../env.sh
source scripts/env.sh

# 2. The tag and the binary cannot disagree: both configurations must carry exactly BASE.
versions="$(awk '/^[[:space:]]*MARKETING_VERSION = /{ sub(/^[^=]*= /, ""); sub(/;$/, ""); print }' \
  Metr.xcodeproj/project.pbxproj | sort -u)"
[ "$versions" = "$BASE" ] \
  || fail "tag version $BASE differs from the project's MARKETING_VERSION (found: $(printf '%s' "$versions" | tr '\n' ' '))"
[ "$(awk '/^[[:space:]]*MARKETING_VERSION = /' Metr.xcodeproj/project.pbxproj | wc -l | tr -d ' ')" = "2" ] \
  || fail "expected MARKETING_VERSION in exactly the two target configurations"

# 3. Build number: the commit count. A shallow clone would make it wrong, so refuse it.
[ "$(git rev-parse --is-shallow-repository)" = "false" ] \
  || fail "shallow clone: the build number needs full history (fetch-depth: 0)"
BUILD="$(git rev-list --count HEAD)"
[[ "$BUILD" =~ ^[0-9]+$ ]] || fail "could not compute the build number"

# 4. Release build with the version overrides. The product is read from the mode's own DerivedData.
METR_MARKETING_VERSION="$BASE" METR_BUILD_NUMBER="$BUILD" bash scripts/build.sh release >&2
BUILT="$METR_DERIVED/Build/Products/Release/Metr.app"
[ -d "$BUILT" ] || fail "build product not found at $BUILT"

# 5. Stage a fresh copy, then sign it last: nothing touches the bundle after this (T-04-15).
[ -n "$METR_RELEASE_STAGE" ] || fail "METR_RELEASE_STAGE is empty"
STAGE_DIR="$METR_RELEASE_STAGE/$VERSION"
case "$STAGE_DIR" in
  "$METR_BUILD_ROOT"/release/v*|"$METR_BUILD_ROOT"/release/[0-9]*) ;;
  *) fail "unexpected stage directory $STAGE_DIR" ;;
esac
rm -rf -- "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
STAGED="$STAGE_DIR/Metr.app"
ditto --noextattr --norsrc "$BUILT" "$STAGED"

codesign --force --sign - --timestamp=none "$STAGED"
codesign --verify --deep --strict "$STAGED" || fail "codesign --verify --deep --strict failed on the staged app"

PLIST="$STAGED/Contents/Info.plist"
[ "$(plutil -extract CFBundleShortVersionString raw -o - "$PLIST")" = "$BASE" ] \
  || fail "CFBundleShortVersionString is not $BASE"
[ "$(plutil -extract CFBundleVersion raw -o - "$PLIST")" = "$BUILD" ] \
  || fail "CFBundleVersion is not $BUILD"

# 6. The verify chain on the staged, signed copy.
bash scripts/verify/bundle.sh "$STAGED" >&2
METR_APP_RELEASE="$STAGED" bash scripts/verify/l10n.sh >&2

sig_info="$(codesign -dvvv "$STAGED" 2>&1)"
CDHASH="$(printf '%s\n' "$sig_info" | sed -n 's/^CDHash=//p' | head -n 1)"
[[ "$CDHASH" =~ ^[0-9a-f]{40}$ ]] || fail "could not read a 40-hex CDHash from the staged app"

if [ -n "$OUT_DIR" ]; then
  echo "OUT=$OUT_DIR" >&2
fi
echo "RELEASE-BUILD OK version=$VERSION build=$BUILD cdhash=$CDHASH app=$STAGED"

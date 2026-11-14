#!/usr/bin/env bash
# Usage: scripts/verify/bundle.sh [app]   (default: the Release app)
# Asserts the FND-01 bundle guarantees. Prints "BUNDLE OK" or "FAIL: <what>".
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
# shellcheck source=../env.sh
source scripts/env.sh

APP="${1:-$METR_APP_RELEASE}"
PLIST="$APP/Contents/Info.plist"
BIN="$APP/Contents/MacOS/Metr"

fail() { echo "FAIL: $1"; exit 1; }

[ -d "$APP" ] || fail "app not found at $APP"

[ "$(plutil -extract LSUIElement raw -o - "$PLIST")" = "true" ] || fail "LSUIElement is not true"
[ "$(plutil -extract LSMinimumSystemVersion raw -o - "$PLIST")" = "26.0" ] || fail "LSMinimumSystemVersion is not 26.0"

expected_id="$(metr_bundle_id)"
[ -n "$expected_id" ] || fail "could not read PRODUCT_BUNDLE_IDENTIFIER from the project"
[ "$(plutil -extract CFBundleIdentifier raw -o - "$PLIST")" = "$expected_id" ] \
  || fail "CFBundleIdentifier does not equal $expected_id"

[ "$(lipo -archs "$BIN")" = "arm64" ] || fail "binary architectures are not exactly arm64"

codesign --verify --deep --strict "$APP" 2>/dev/null || fail "codesign --verify --deep --strict failed"
# Capture output first: `grep -q` closing the pipe early would SIGPIPE codesign under pipefail.
sig_info="$(codesign -dv "$APP" 2>&1)"
case "$sig_info" in
  *Signature=adhoc*) ;;
  *) fail "signature is not Signature=adhoc" ;;
esac

ent_info="$(codesign -d --entitlements - "$APP" 2>&1)"
case "$ent_info" in
  *app-sandbox*) fail "app-sandbox entitlement present" ;;
esac

# Keys that must never be present. The Liquid Glass opt-out key name is split
# so this script does not itself contain the literal.
glass_optout="UIDesignRequires""Compatibility"
if grep -aq 'NSAllowsArbitraryLoads' "$PLIST"; then fail "Info.plist contains NSAllowsArbitraryLoads"; fi
if grep -aq "$glass_optout" "$PLIST"; then fail "Info.plist contains $glass_optout"; fi

# DEBUG-only hook environment names must be compiled out of Release.
debug_prefix="METR_""DEBUG"
hits="$(strings -a "$BIN" | grep -c "$debug_prefix" || true)"
[ "$hits" = "0" ] || fail "Release binary contains $hits occurrence(s) of the DEBUG hook prefix"

# Icon gate (DSGN-02): the layered AppIcon must be compiled into the bundle.
[ "$(plutil -extract CFBundleIconName raw -o - "$PLIST" 2>/dev/null || true)" = "AppIcon" ] \
  || fail "CFBundleIconName is not AppIcon"
[ -s "$APP/Contents/Resources/AppIcon.icns" ] || fail "Contents/Resources/AppIcon.icns is missing or empty"
# Capture first: a pipe closing early would SIGPIPE assetutil under pipefail.
car_info="$(assetutil --info "$APP/Contents/Resources/Assets.car" 2>/dev/null || true)"
[ -n "$car_info" ] || fail "assetutil could not read Contents/Resources/Assets.car"
printf '%s' "$car_info" | python3 -I -c '
import json, sys
entries = json.load(sys.stdin)
ok = any(e.get("AssetType") == "IconImageStack" and e.get("Name") == "AppIcon" for e in entries if isinstance(e, dict))
sys.exit(0 if ok else 1)
' || fail "Assets.car has no IconImageStack named AppIcon"

echo "BUNDLE OK"

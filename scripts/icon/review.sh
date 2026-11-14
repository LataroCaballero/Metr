#!/usr/bin/env bash
# Usage: scripts/icon/review.sh
# Renders Metr/AppIcon.icon with the ictool inside Icon Composer in Default, Dark,
# TintedDark and ClearLight (plus TintedLight and ClearDark when ictool accepts them)
# at 1024, 128, 32 and 16 px for the owner's review (D-09).
# Writes only under $METR_PREVIEWS/icon. Prints "ICON-REVIEW OK dir=<path> renders=<n>".
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
# shellcheck source=../env.sh
source scripts/env.sh

fail() { echo "FAIL: $1" >&2; exit 1; }

IC="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
[ -x "$IC" ] || fail "ictool not found at $IC"
[ -f Metr/AppIcon.icon/icon.json ] || fail "Metr/AppIcon.icon/icon.json is missing"

DIR="$METR_PREVIEWS/icon"
mkdir -p "$DIR"
rm -f "$DIR"/icon-*.png

required="Default Dark TintedDark ClearLight"
optional="TintedLight ClearDark"
sizes="1024 128 32 16"
renders=0
ran=""
skipped=""

render_one() { # rendition size -> 0 when the PNG exists with the requested pixel size
  local rendition="$1" size="$2" out
  out="$DIR/icon-$rendition-$size.png"
  "$IC" Metr/AppIcon.icon --export-image --output-file "$out" --platform macOS \
    --rendition "$rendition" --width "$size" --height "$size" --scale 1 >/dev/null 2>&1 || return 1
  [ -s "$out" ] || return 1
  [ "$(sips -g pixelWidth "$out" | awk '/pixelWidth/{print $2}')" = "$size" ] || return 1
  return 0
}

for rendition in $required; do
  for size in $sizes; do
    render_one "$rendition" "$size" || fail "ictool could not render $rendition at $size px"
    renders=$((renders + 1))
  done
  ran="$ran $rendition"
done

for rendition in $optional; do
  ok=1
  for size in $sizes; do
    render_one "$rendition" "$size" || { ok=0; break; }
  done
  if [ "$ok" = 1 ]; then
    renders=$((renders + 4))
    ran="$ran $rendition"
  else
    rm -f "$DIR"/icon-"$rendition"-*.png
    skipped="$skipped $rendition"
  fi
done

echo "renditions rendered:$ran" >&2
echo "renditions skipped:${skipped:- none}" >&2
echo "ICON-REVIEW OK dir=$DIR renders=$renders"

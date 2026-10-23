#!/usr/bin/env bash
# Usage: scripts/verify/glyph-previews.sh
# Runs RingGlyphTests with METR_GLYPH_PREVIEW_DIR set so the tests write 1x/2x light/dark PNG
# previews of every glyph state. Prints "GLYPH-PREVIEWS OK dir=<path>".
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
# shellcheck source=../env.sh
source scripts/env.sh

DIR="$METR_PREVIEWS/glyph"
mkdir -p "$DIR"
rm -f "$DIR"/glyph-*.png

METR_GLYPH_PREVIEW_DIR="$DIR" bash scripts/test.sh 'RingGlyphTests'

for f in glyph-1x-light-rest.png glyph-2x-dark-diskCritical.png glyph-1x-dark-memWarn.png; do
  [ -s "$DIR/$f" ] || { echo "FAIL: missing preview $DIR/$f" >&2; exit 1; }
done

echo "GLYPH-PREVIEWS OK dir=$DIR"

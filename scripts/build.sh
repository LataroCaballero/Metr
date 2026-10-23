#!/usr/bin/env bash
# Usage: scripts/build.sh release|debug
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "$SCRIPT_DIR/env.sh"
bash "$SCRIPT_DIR/preflight.sh"

case "${1:-}" in
  release) CONFIG=Release; APP="$METR_APP_RELEASE" ;;
  debug)   CONFIG=Debug;   APP="$METR_APP_DEBUG" ;;
  *) echo "usage: scripts/build.sh release|debug" >&2; exit 2 ;;
esac

mkdir -p "$METR_DERIVED" "$METR_LOGS"

xcodebuild \
  -project Metr.xcodeproj \
  -scheme Metr \
  -configuration "$CONFIG" \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$METR_DERIVED" \
  -quiet \
  build

echo "APP=$APP"

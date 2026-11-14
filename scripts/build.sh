#!/usr/bin/env bash
# Usage: scripts/build.sh release|debug|relhooks
#   release   the shipping build (Release configuration) into $METR_DERIVED
#   debug     the Debug build into $METR_DERIVED
#   relhooks  Release optimization with the DEBUG compilation condition, into
#             $METR_BUILD_ROOT/DerivedData-relhooks: the build the window script and the runtime
#             checks can drive (a true Release app has no hooks)
# Optional overrides for the release path: METR_MARKETING_VERSION and METR_BUILD_NUMBER become the
# MARKETING_VERSION= and CURRENT_PROJECT_VERSION= xcodebuild settings.
# Prints "APP=<path>": the product inside the DerivedData of the mode, never a preset METR_APP_RELEASE.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "$SCRIPT_DIR/env.sh"
bash "$SCRIPT_DIR/preflight.sh"

extra=()
case "${1:-}" in
  release)
    CONFIG=Release; DERIVED="$METR_DERIVED"
    APP="$DERIVED/Build/Products/Release/Metr.app" ;;
  debug)
    CONFIG=Debug; DERIVED="$METR_DERIVED"
    APP="$DERIVED/Build/Products/Debug/Metr.app" ;;
  relhooks)
    CONFIG=Release; DERIVED="$METR_BUILD_ROOT/DerivedData-relhooks"
    APP="$DERIVED/Build/Products/Release/Metr.app"
    extra+=("SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG") ;;
  *) echo "usage: scripts/build.sh release|debug|relhooks" >&2; exit 2 ;;
esac

if [ -n "${METR_MARKETING_VERSION:-}" ]; then
  extra+=("MARKETING_VERSION=$METR_MARKETING_VERSION")
fi
if [ -n "${METR_BUILD_NUMBER:-}" ]; then
  extra+=("CURRENT_PROJECT_VERSION=$METR_BUILD_NUMBER")
fi

mkdir -p "$DERIVED" "$METR_LOGS"

xcodebuild \
  -project Metr.xcodeproj \
  -scheme Metr \
  -configuration "$CONFIG" \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED" \
  -quiet \
  build \
  ${extra[@]+"${extra[@]}"}

echo "APP=$APP"

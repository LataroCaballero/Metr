#!/usr/bin/env bash
# Sourced by the other scripts. Computes where all build output lives.
# Everything goes under /Volumes/XcodeDev (the internal disk is nearly full).

METR_ROOT="$(git rev-parse --show-toplevel)"
export METR_ROOT

# CI mode (METR_CI=1, or GITHUB_ACTIONS=true on the runner): build output goes under RUNNER_TEMP,
# there is no sparsebundle, and preflight.sh keeps only the exact Xcode assertion. Locally nothing changes.
if [ "${METR_CI:-0}" = "1" ] || [ "${GITHUB_ACTIONS:-}" = "true" ]; then
  export METR_CI=1
  export METR_BUILD_ROOT="${RUNNER_TEMP:?RUNNER_TEMP must be set in CI mode}/metr-build"
else
  export METR_CI=0
  _metr_hash="$(printf '%s' "$METR_ROOT" | shasum | cut -c1-10)"
  export METR_BUILD_ROOT="/Volumes/XcodeDev/metr-build/${_metr_hash}"
  unset _metr_hash
fi
export METR_DERIVED="$METR_BUILD_ROOT/DerivedData"
export METR_SPM="$METR_BUILD_ROOT/spm"
export METR_LOGS="$METR_BUILD_ROOT/logs"
export METR_PREVIEWS="$METR_BUILD_ROOT/previews"
# A value already set in the environment wins, so the perf and gate scripts can measure any built copy
# (for example the app extracted from the CI DMG). build.sh never reads these two: it prints the product
# inside the DerivedData of its own mode.
export METR_APP_RELEASE="${METR_APP_RELEASE:-$METR_DERIVED/Build/Products/Release/Metr.app}"
export METR_APP_DEBUG="$METR_DERIVED/Build/Products/Debug/Metr.app"
# Release optimization with the DEBUG compilation condition (scripts/build.sh relhooks): the build the
# window-script and the zero-network runtime checks can drive.
export METR_APP_RELHOOKS="${METR_APP_RELHOOKS:-$METR_BUILD_ROOT/DerivedData-relhooks/Build/Products/Release/Metr.app}"
# Where scripts/release/build-release.sh stages the final, re-signed app (<stage>/<version>/Metr.app).
export METR_RELEASE_STAGE="$METR_BUILD_ROOT/release"

# Print PRODUCT_BUNDLE_IDENTIFIER from the project file.
metr_bundle_id() {
  awk '/^[[:space:]]*PRODUCT_BUNDLE_IDENTIFIER = /{ sub(/^[^=]*= /, ""); sub(/;$/, ""); print; exit }' \
    "$METR_ROOT/Metr.xcodeproj/project.pbxproj"
}

# Terminate any running Metr and wait up to 5 s for it to exit.
metr_kill() {
  pkill -x Metr 2>/dev/null || true
  local i
  for i in $(seq 1 50); do
    pgrep -x Metr >/dev/null 2>&1 || return 0
    sleep 0.1
  done
  echo "metr_kill: Metr still running after 5 s" >&2
  return 1
}

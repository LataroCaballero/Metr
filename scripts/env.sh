#!/usr/bin/env bash
# Sourced by the other scripts. Computes where all build output lives.
# Everything goes under /Volumes/XcodeDev (the internal disk is nearly full).

METR_ROOT="$(git rev-parse --show-toplevel)"
export METR_ROOT

_metr_hash="$(printf '%s' "$METR_ROOT" | shasum | cut -c1-10)"
export METR_BUILD_ROOT="/Volumes/XcodeDev/metr-build/${_metr_hash}"
export METR_DERIVED="$METR_BUILD_ROOT/DerivedData"
export METR_SPM="$METR_BUILD_ROOT/spm"
export METR_LOGS="$METR_BUILD_ROOT/logs"
export METR_PREVIEWS="$METR_BUILD_ROOT/previews"
export METR_APP_RELEASE="$METR_DERIVED/Build/Products/Release/Metr.app"
export METR_APP_DEBUG="$METR_DERIVED/Build/Products/Debug/Metr.app"
unset _metr_hash

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

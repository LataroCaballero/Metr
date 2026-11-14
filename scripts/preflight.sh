#!/usr/bin/env bash
# Verifies the toolchain pin and disk space. Prints "PREFLIGHT OK" on success.
set -euo pipefail

XCODE_APP="/Volumes/XcodeDev/Xcode.app"
SPARSEBUNDLE="/Volumes/Lexar/XcodeDev.sparsebundle"

# CI mode (METR_CI=1 or GITHUB_ACTIONS=true): no sparsebundle, no xcode-select path and no disk checks
# (the workflow selects Xcode itself); the exact Xcode version assertion below still applies.
CI_MODE=0
if [ "${METR_CI:-0}" = "1" ] || [ "${GITHUB_ACTIONS:-}" = "true" ]; then CI_MODE=1; fi

if [ "$CI_MODE" = "0" ]; then
  if [ ! -d "$XCODE_APP" ]; then
    echo "Xcode volume not mounted; attaching $SPARSEBUNDLE" >&2
    hdiutil attach "$SPARSEBUNDLE" >/dev/null
  fi

  if [ ! -d "$XCODE_APP" ]; then
    echo "FAIL: $XCODE_APP is missing" >&2
    exit 1
  fi

  selected="$(xcode-select -p)"
  if [ "$selected" != "$XCODE_APP/Contents/Developer" ]; then
    echo "FAIL: xcode-select -p is '$selected', expected '$XCODE_APP/Contents/Developer'" >&2
    echo "      run: sudo xcode-select -s $XCODE_APP/Contents/Developer" >&2
    exit 1
  fi
fi

# No `| head` here: under pipefail, SIGPIPE to xcodebuild intermittently fails the script.
version_out="$(xcodebuild -version)"
version_line="${version_out%%$'\n'*}"
if [ "$version_line" != "Xcode 26.6" ]; then
  echo "FAIL: xcodebuild -version says '$version_line', expected exactly 'Xcode 26.6'" >&2
  exit 1
fi

if [ "$CI_MODE" = "0" ]; then
  free_kib="$(df -k / | awk 'NR==2 {print $4}')"
  if [ "$free_kib" -lt $((2 * 1024 * 1024)) ]; then
    echo "FAIL: internal disk has less than 2 GiB free (${free_kib} KiB)" >&2
    exit 1
  fi
fi

echo "$version_line"
if [ "$CI_MODE" = "1" ]; then
  echo "PREFLIGHT OK (ci)"
else
  echo "PREFLIGHT OK"
fi

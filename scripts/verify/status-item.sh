#!/usr/bin/env bash
# Usage: scripts/verify/status-item.sh [app]   (default: the Release app)
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
# shellcheck source=../env.sh
source scripts/env.sh

metr_kill
# Let Control Center drop the previous instance's status window so the baseline is clean.
sleep 2
swift scripts/verify/status-item.swift "${1:-$METR_APP_RELEASE}"

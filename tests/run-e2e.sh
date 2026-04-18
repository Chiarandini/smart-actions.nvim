#!/usr/bin/env bash
# End-to-end test runner. Each case hits real Claude Code (or Anthropic API),
# so this is opt-in and takes ~1–2 minutes.
#
# Usage:
#   ./tests/run-e2e.sh

set -euo pipefail
cd "$(dirname "$0")/.."

SA_E2E=1 NVIM_APPNAME="${NVIM_APPNAME:-noethervim}" nvim --headless \
	--cmd "set rtp+=$(pwd)" \
	-c "luafile tests/e2e_spec.lua" \
	-c "qa!" 2>&1 | grep -v "zoxide\|Disable\|github\|Please\|configuration issue\|Shell cwd"

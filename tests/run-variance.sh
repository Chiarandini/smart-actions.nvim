#!/usr/bin/env bash
# Run the variance harness against the undefined_name fixture.
# Requires NVIM_APPNAME=noethervim (or any nvim setup that loads smart-actions).
#
# Override: SA_RUNS=20 SA_CURSOR_ROW=7 SA_SCOPE=file ./tests/run-variance.sh

set -euo pipefail
cd "$(dirname "$0")/.."

RUNS="${SA_RUNS:-5}"
SCOPE="${SA_SCOPE:-file}"
CURSOR="${SA_CURSOR_ROW:-7}"

NVIM_APPNAME="${NVIM_APPNAME:-noethervim}" nvim --headless \
	-c "lua _G.SA_RUNS=$RUNS; _G.SA_SCOPE='$SCOPE'; _G.SA_CURSOR_ROW=$CURSOR" \
	-c "edit tests/fixtures/undefined_name.py" \
	-c "luafile tests/variance.lua" \
	-c "qa!" 2>&1 | grep -v "zoxide\|Disable\|github\|Please\|configuration issue\|Shell cwd"

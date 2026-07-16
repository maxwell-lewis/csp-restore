#!/bin/bash
# Run Crimson Steam Pirates with the bundled moai host.
#
# Usage:
#   ./run.sh              -- run normally
#   ./run.sh --log FILE   -- tee all output to FILE as well as stdout
#   ./run.sh --quiet      -- suppress per-frame leak-tracker noise

cd "$(dirname "$0")"

if [ ! -x ./moai ]; then
    echo "ERROR: ./moai is missing or not executable." >&2
    echo "If you downloaded this without preserving permissions, run: chmod +x moai run.sh" >&2
    exit 1
fi

if [ "$1" = "--log" ] && [ -n "$2" ]; then
    ./moai boot.lua 2>&1 | tee "$2"
elif [ "$1" = "--quiet" ]; then
    ./moai boot.lua 2>&1 | grep -vE "^Allocation:|^\s*0x[0-9a-f]|^\s*Lua Ref:|^stack traceback:|^-- (BEGIN|END) LUA"
else
    ./moai boot.lua "$@"
fi

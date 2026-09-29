#!/usr/bin/env bash
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"
# Probe for bundled LuaJIT
LUAJIT_BIN=""
CANDIDATES=(
    "${KOREADER_APP_DIR:-}/luajit"
    "/usr/lib/koreader/luajit"
    "/home/jimmy/squashfs-root/usr/lib/koreader/luajit"
    "/home/${USER:-}/squashfs-root/usr/lib/koreader/luajit"
    "$(which luajit 2>/dev/null || true)"
)
for c in "${CANDIDATES[@]}"; do
    if [ -x "$c" ]; then
        LUAJIT_BIN="$c"
        break
    fi
done

if [ -n "$LUAJIT_BIN" ] && [ -f "$SCRIPT_DIR/spec_runner.lua" ]; then
    exec "$LUAJIT_BIN" "$SCRIPT_DIR/spec_runner.lua" "$@"
else
    exec busted tests -p _test "$@"
fi

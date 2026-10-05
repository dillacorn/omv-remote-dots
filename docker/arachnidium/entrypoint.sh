#!/bin/sh
set -eu

cd /opt/arachnidium
bun run bun-api/index.ts &
bun_pid=$!
uv run python main-http.py &
proxy_pid=$!

cleanup() {
    kill "$proxy_pid" "$bun_pid" 2>/dev/null || true
    wait "$proxy_pid" 2>/dev/null || true
    wait "$bun_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

wait "$proxy_pid"

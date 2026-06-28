#!/usr/bin/env bash
# Liveness probe for the personal-mcp server. Pings its healthcheck on success and
# /fail when the server doesn't respond, so a wedged/down daemon gets alerted even
# though launchd KeepAlive normally restarts it. Run frequently by a LaunchAgent.
#
# Mini-only: guarded by the hub data dir (same capability gate as personal-mcp.sh).
# Silent on success; prints only on failure (captured to the launchd log).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

[ -d "$HOME/archives/hub" ] || exit 0   # not the archive host

PORT="${HUB_MCP_PORT:-8765}"
URL="http://127.0.0.1:${PORT}/mcp"

# A live server answers a bare POST with a JSON error (e.g. 400 "Missing session
# ID"); a closed or wedged server yields no HTTP response (curl prints 000).
code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' -X POST "$URL" \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' 2>/dev/null || echo 000)

if [ -n "$code" ] && [ "$code" != "000" ]; then
    pm_hc mcp-server
else
    echo "$(date '+%F %T') mcp-server not responding at $URL (code=$code)"
    pm_hc mcp-server /fail --data-raw "personal-mcp server not responding at $URL (code=$code)"
fi

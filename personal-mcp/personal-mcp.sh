#!/usr/bin/env bash
# Run the personal-mcp server (unified search over email/iMessage/calendar/web).
#
# Capability-guarded: no-ops on machines without the project, so it is safe to
# deploy everywhere via the stow-managed LaunchAgent but only runs on the archive
# host (klundstedt-mini). The server binds 127.0.0.1:8765; `tailscale serve`
# exposes it tailnet-only over HTTPS at https://<node>.<tailnet>.ts.net/mcp.
#
# Kept alive by a LaunchAgent (KeepAlive on crash). See
#   launchd/Library/LaunchAgents/com.kylelundstedt.personal-mcp.plist
set -uo pipefail

PROJ="$HOME/archives/hub/mcp"
[ -d "$PROJ" ] || { echo "no $PROJ; skipping."; exit 0; }
command -v uv >/dev/null 2>&1 || { echo "uv not installed; skipping."; exit 0; }

cd "$PROJ" || exit 1
export HUB_MCP_HOST="${HUB_MCP_HOST:-127.0.0.1}"
export HUB_MCP_PORT="${HUB_MCP_PORT:-8765}"
exec uv run python server.py

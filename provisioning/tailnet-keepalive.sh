#!/usr/bin/env bash
# tailnet-keepalive — hold the home<->exe.dev tailnet paths on a DIRECT WireGuard
# path instead of letting them idle out to DERP.
#
# The exe.dev VMs sit behind a NAT with a short UDP mapping timeout. It is
# endpoint-independent (netcheck MappingVariesByDestIP=false), so hole-punching
# SUCCEEDS and a direct path forms under active traffic (~20ms) — but an idle
# path's mapping expires in ~1-2 min, the VM's public UDP port remaps, the path
# drops to DERP, and cold-recovery on the next use occasionally takes MINUTES
# (the home side logs `open-conn-track: timeout ... online=yes, lastRecv=...5m`).
# That gap flapped the agentsview healthcheck ~2-4x/day (2026-07-26/27). Pinging
# each source under the NAT timeout keeps the mapping fresh and holds the path
# direct. See agent_docs/monitoring.md and boldsoftware/exe.dev#220 — the durable
# fix is exe.dev exposing stable inbound UDP 41641 / public IPs (Tailscale's
# cloud-NAT guidance), which would make this keepalive unnecessary.
#
# Mini-only; runs as a KeepAlive LaunchAgent (com.kylelundstedt.tailnet-keepalive).
set -uo pipefail
# launchd's `bash -l -c` does not reliably put Homebrew on PATH (it resolves
# python3 to /usr/bin), so the tailscale CLI must be found explicitly.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

[[ "$(scutil --get LocalHostName 2>/dev/null)" == "klundstedt-mini" ]] || { echo "not klundstedt-mini; skipping."; exit 0; }
command -v tailscale >/dev/null 2>&1 || { echo "tailscale CLI not found on PATH; skipping."; exit 0; }

# Keep exactly the hosts agentsview monitors warm — same source of truth as the
# healthcheck, re-read each cycle so config edits apply without a reload.
CFG="${AGENTSVIEW_CONFIG:-$HOME/.agentsview/config.toml}"
INTERVAL="${TAILNET_KEEPALIVE_INTERVAL:-15}"   # seconds; must stay under the NAT UDP timeout

echo "$(date '+%F %T') tailnet-keepalive start (interval=${INTERVAL}s, config=$CFG)"
while :; do
    hosts=$(grep -E '^[[:space:]]*host[[:space:]]*=' "$CFG" 2>/dev/null | sed -E 's/.*"([^"]+)".*/\1/')
    # Iterate line-by-line (IFS-independent) — word-splitting on $hosts is fragile.
    while IFS= read -r h; do
        [[ -n "$h" ]] || continue
        # One probe per host: keeps the WireGuard path active and nudges it direct.
        tailscale ping --c 1 --timeout 3s "$h" >/dev/null 2>&1 || true
    done <<< "$hosts"
    sleep "$INTERVAL"
done

#!/usr/bin/env bash
# join-tailnet — bring an exe.dev VM onto IV's tailnet on demand.
#
# Usage: join-tailnet.sh <vm-name>
#
# SSHes into <vm>.exe.xyz (the exe.dev edge path — works before the VM is on the
# tailnet) and runs `tailscale up` with a one-use, ephemeral, preauthorized key
# minted through exe.dev's tailscale-api HTTP proxy. The Tailscale API secret
# never touches the VM; exe.dev injects it at the proxy layer.
#
# Preconditions (all satisfied by iv-image >= 2.0.0 created with --tag=iv):
#   - tailscaled enabled and running on the VM
#   - curl + jq present on the VM
#   - the `tailscale-api` integration attached to the VM
#
# Env overrides: IV_TAILSCALE_TAG (default tag:dev),
#                IV_TAILSCALE_API_URL (default https://tailscale-api.int.exe.xyz)
set -euo pipefail

VM=${1:?usage: join-tailnet.sh <vm-name>}
TAG=${IV_TAILSCALE_TAG:-tag:dev}
PROXY=${IV_TAILSCALE_API_URL:-https://tailscale-api.int.exe.xyz}

exec ssh -o ConnectTimeout=30 -o StrictHostKeyChecking=accept-new "${VM}.exe.xyz" \
  TAG="$TAG" PROXY="$PROXY" 'bash -s' <<'REMOTE'
set -euo pipefail
: "${TAG:?}" "${PROXY:?}"

state=$(tailscale status --json 2>/dev/null | jq -r '.BackendState // empty' || true)
if [ "$state" = "Running" ]; then
  echo "already on tailnet:"
  tailscale status
  exit 0
fi

# Two-step (U11, 2026-07): the proxy injects the Tailscale OAuth client's
# Basic credentials on every request, so only the token exchange goes through
# it; the short-lived Bearer token then mints against the public API directly.
token=$(curl -fsSL --connect-timeout 5 --max-time 15 \
  -X POST -d "grant_type=client_credentials" \
  "${PROXY%/}/api/v2/oauth/token" | jq -r '.access_token // empty' || true)
if [ -z "$token" ]; then
  echo "join-tailnet: OAuth token exchange via ${PROXY} failed" >&2
  echo "  is the tailscale-api integration attached to this VM (--tag=iv)?" >&2
  exit 1
fi

key=$(curl -fsSL --connect-timeout 5 --max-time 15 \
  -H "Authorization: Bearer $token" \
  -H "Content-Type: application/json" \
  -X POST "https://api.tailscale.com/api/v2/tailnet/-/keys" \
  -d "{\"capabilities\":{\"devices\":{\"create\":{\"reusable\":false,\"ephemeral\":true,\"preauthorized\":true,\"tags\":[\"${TAG}\"]}}},\"expirySeconds\":600}" \
  | jq -r '.key // empty' || true)

case "$key" in
  tskey-*) ;;
  *) echo "join-tailnet: failed to mint auth key (token OK, mint failed — check the OAuth client's auth_keys scope / ${TAG} tag)" >&2
     exit 1 ;;
esac

# Ensure tailscaled is running. iv-image enables it, but stock exeuntu may not —
# start it if the socket isn't present, then wait for it.
sock() { [ -S /var/run/tailscale/tailscaled.sock ] || [ -S /run/tailscale/tailscaled.sock ]; }
if ! sock; then
  sudo systemctl start tailscaled 2>/dev/null || true
fi
for _ in $(seq 1 30); do sock && break; sleep 1; done
if ! sock; then
  echo "join-tailnet: tailscaled socket never appeared (is Tailscale installed on this VM?)" >&2
  exit 1
fi

sudo tailscale up --ssh --accept-dns --hostname="$(hostname)" --authkey="$key" --timeout=60s
tailscale status
REMOTE

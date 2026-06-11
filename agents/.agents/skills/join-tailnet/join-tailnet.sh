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

key=$(curl -fsSL --connect-timeout 5 --max-time 15 \
  -H "Content-Type: application/json" \
  -X POST "${PROXY%/}/api/v2/tailnet/-/keys" \
  -d "{\"capabilities\":{\"devices\":{\"create\":{\"reusable\":false,\"ephemeral\":true,\"preauthorized\":true,\"tags\":[\"${TAG}\"]}}},\"expirySeconds\":600}" \
  | jq -r '.key // empty' || true)

case "$key" in
  tskey-*) ;;
  *) echo "join-tailnet: failed to mint auth key from ${PROXY}" >&2
     echo "  is the tailscale-api integration attached to this VM (--tag=iv)?" >&2
     exit 1 ;;
esac

# tailscaled is enabled in iv-image but sshd may be reachable before it; wait.
for _ in $(seq 1 30); do
  if [ -S /var/run/tailscale/tailscaled.sock ] || [ -S /run/tailscale/tailscaled.sock ]; then break; fi
  sleep 1
done

sudo tailscale up --ssh --accept-dns --hostname="$(hostname)" --authkey="$key" --timeout=60s
tailscale status
REMOTE

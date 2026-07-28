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
#
# ATTACH-THEN-DETACH (2026-07-28). `tailscale-api` used to be attached
# `auto:all`, so every VM — including the public-facing ones — could mint
# tailnet auth keys, remove nodes, and edit ACLs at any time. Verified from
# rss-feed: the proxy returned HTTP 200 on a token exchange. It is now attached
# by this script for the duration of the join and detached on exit, so the
# authority exists only while it is being used. The trap fires on error and on
# interrupt, not just on success — if it ever does leak, `integrations list`
# will show a stray `vm:` attachment.
#
# Env overrides: IV_TAILSCALE_TAG (default tag:dev),
#                IV_TAILSCALE_API_URL (default https://tailscale-api.int.exe.xyz)
set -euo pipefail

VM=${1:?usage: join-tailnet.sh <vm-name>}
TAG=${IV_TAILSCALE_TAG:-tag:dev}
PROXY=${IV_TAILSCALE_API_URL:-https://tailscale-api.int.exe.xyz}

# Was it already attached before we got here? If so, leave it exactly as found
# rather than detaching something we did not attach.
preexisting=false
if ssh -o ConnectTimeout=30 exe.dev integrations list 2>/dev/null \
   | awk -v vm="vm:$VM" '$1=="tailscale-api" && index($0, vm) {found=1} END{exit !found}'; then
  preexisting=true
  echo "join-tailnet: tailscale-api already attached to $VM — leaving attachment as found" >&2
else
  echo "join-tailnet: attaching tailscale-api to $VM for the duration of the join" >&2
  ssh -o ConnectTimeout=30 exe.dev integrations attach tailscale-api "vm:$VM" >/dev/null \
    || { echo "join-tailnet: could not attach tailscale-api to $VM" >&2; exit 1; }
fi

detach() {
  [ "$preexisting" = true ] && return 0
  echo "join-tailnet: detaching tailscale-api from $VM" >&2
  ssh -o ConnectTimeout=30 exe.dev integrations detach tailscale-api "vm:$VM" >/dev/null \
    || echo "join-tailnet: WARNING — failed to detach tailscale-api from $VM; detach it manually" >&2
}
trap detach EXIT INT TERM

ssh -o ConnectTimeout=30 -o StrictHostKeyChecking=accept-new "${VM}.exe.xyz" \
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

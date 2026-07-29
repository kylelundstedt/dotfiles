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
# RETRY rather than trusting one call. Observed 2026-07-29 on a fresh VM: this
# exchange returned 403 immediately after `integrations attach` succeeded, and
# the whole join aborted. A manual re-attach then probed 200 on its FIRST try,
# and a full re-run of this script also succeeded first try — so the failure is
# intermittent and the obvious "attachment takes a few seconds to propagate"
# story is NOT established. One 403, two immediate successes, cause unconfirmed.
#
# The retry is therefore defensive, not a fix for a diagnosed race. It costs
# nothing when the first call works. If this ever burns all six attempts the
# cause is something else and the message below says where to look.
#
# Note this window is new: before the attach-then-detach change the integration
# was attached at creation, so nothing ever called the proxy seconds after an
# attach.
#
# Never print a response body here: it carries the access token.
token=""
for attempt in 1 2 3 4 5 6; do
  token=$(curl -fsSL --connect-timeout 5 --max-time 15 \
    -X POST -d "grant_type=client_credentials" \
    "${PROXY%/}/api/v2/oauth/token" 2>/dev/null | jq -r '.access_token // empty' 2>/dev/null || true)
  [ -n "$token" ] && break
  echo "join-tailnet: proxy not ready (attempt $attempt/6); retrying in 10s" >&2
  sleep 10
done
if [ -z "$token" ]; then
  echo "join-tailnet: OAuth token exchange via ${PROXY} failed after 6 attempts" >&2
  echo "  the attach propagates in seconds, so this is not the delay — check" >&2
  echo "  'integrations list' for a tailscale-api attachment on this VM, and" >&2
  echo "  'integrations test tailscale-api' for the credential itself." >&2
  exit 1
fi

# Clear any node already holding this hostname, or Tailscale hands us
# "<name>-1" and every consumer that addresses the VM by name silently talks to
# the wrong node — or to nothing. Hit on 2026-07-29 retiring iv-ave-adapters:
# the replacement registered as iv-ave-adapters-1 because the deleted VM's
# ephemeral node had not been reaped yet, and the collector entry pointed at the
# dead one. install.sh's Linux path has carried this same cleanup for a while
# ("prevents -2 suffix"); join-tailnet did not.
#
# Only nodes whose hostname matches AND which are not this machine are removed.
want_host=$(hostname)
myips=$(tailscale status --json 2>/dev/null | jq -r '(.Self.TailscaleIPs // [])[]' | tr '\n' ' ')
for stale in $(curl -fsSL --max-time 15 -H "Authorization: Bearer $token" \
      https://api.tailscale.com/api/v2/tailnet/-/devices 2>/dev/null \
    | jq -r --arg h "$want_host" --arg ips "$myips" \
        '.devices[] | select(.hostname==$h)
         | select((.addresses // []) | map(. as $a | ($ips | contains($a))) | any | not) | .id' 2>/dev/null); do
  echo "join-tailnet: removing stale node holding $want_host (id=$stale)" >&2
  curl -fsSL --max-time 15 -X DELETE -H "Authorization: Bearer $token" \
    "https://api.tailscale.com/api/v2/device/$stale" >/dev/null 2>&1 || true
done

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

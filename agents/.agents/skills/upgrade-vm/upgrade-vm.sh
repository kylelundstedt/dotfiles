#!/usr/bin/env bash
# upgrade-vm — reprovision an exe.dev VM onto a new image WITHOUT a -1 tailnet name.
#
# Usage: upgrade-vm.sh <vm-name> [image]
#
# exe.dev consumes the image only at VM creation, so "upgrade" = destroy +
# recreate with the same name. If the old ephemeral Tailscale node still holds
# the name when the new VM joins, the new VM lands as <name>-1.
#
# This runs from a CONTROL NODE that can reach the tailscale-api proxy (an
# exe.dev VM with the tailscale-api integration attached, e.g. iv-registry). It:
#   1. destroys the old VM
#   2. deletes the stale tailnet node(s) for that hostname and waits for it to clear
#   3. recreates the VM from the target image
#   4. joins it via the join-tailnet skill
#
# Device-delete authority stays here on the control node — never on the
# disposable VM (that is the point of iv-image >= 2.0.0).
#
# Env overrides: IV_TAILSCALE_API_URL, IV_VM_TAG (default iv), IV_VM_IMAGE
set -euo pipefail

VM=${1:?usage: upgrade-vm.sh <vm-name> [image]}
IMAGE=${2:-${IV_VM_IMAGE:-iv-registry.exe.xyz:5000/iv-image:2}}
TAG=${IV_VM_TAG:-iv}
PROXY=${IV_TAILSCALE_API_URL:-https://tailscale-api.int.exe.xyz}

SKILL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
JOIN="${SKILL_DIR}/../join-tailnet/join-tailnet.sh"
[ -x "$JOIN" ] || JOIN="$HOME/.agents/skills/join-tailnet/join-tailnet.sh"

log() { printf 'upgrade-vm: %s\n' "$*" >&2; }

stale_ids() {
  curl -fsSL --max-time 10 "${PROXY%/}/api/v2/tailnet/-/devices" \
    | jq -r --arg h "$VM" '.devices[] | select(.hostname == $h) | .id'
}

# 1. destroy the old VM (ok if it does not exist yet — first provision)
log "destroying old VM '$VM' (if any)"
ssh -o ConnectTimeout=30 exe.dev rm "$VM" 2>&1 | sed 's/^/  rm> /' || true

# 2. delete stale tailnet node(s) with this hostname; poll until the name clears.
#    Filtering on .hostname catches both <name> and a prior <name>-1.
for _ in $(seq 1 12); do
  ids=$(stale_ids || true)
  [ -z "$ids" ] && break
  for id in $ids; do
    log "deleting stale tailnet node id=$id"
    curl -fsS -o /dev/null -X DELETE "${PROXY%/}/api/v2/device/$id" || true
  done
  sleep 3
done
if [ -n "$(stale_ids || true)" ]; then
  log "stale node(s) for '$VM' still present after retries — aborting to avoid -1"
  exit 1
fi
log "no stale tailnet node for '$VM'"

# 3. create the new VM from the target image
log "creating '$VM' from $IMAGE (--tag=$TAG)"
ssh -o ConnectTimeout=30 exe.dev new --name="$VM" --tag="$TAG" --image="$IMAGE" 2>&1 | sed 's/^/  new> /'

# 4. let it become SSH-reachable, then join (single attempt — no *.exe.xyz SYN burst)
sleep 8
log "joining '$VM' to the tailnet"
"$JOIN" "$VM"

log "done — '$VM' upgraded to $IMAGE and on the tailnet"

#!/bin/bash
# exe.dev default-setup-script — fetched at first boot of every new VM.
# Registered via:
#   ssh exe.dev "defaults write dev.exe new.setup-script \
#     'curl -fsSL https://raw.githubusercontent.com/kylelundstedt/dotfiles/master/exe-setup.sh | bash'"
#
# Brings Tailscale up FAST via the exe.dev tailscale-api HTTP proxy
# integration (no secrets on VM disk).

set -e

PROXY=https://tailscale-api.int.exe.xyz
TS_HOSTNAME=$(hostname)

# Delete stale Tailscale nodes with this hostname (prevents -2 suffix on rebuild)
for did in $(curl -sL "$PROXY/api/v2/tailnet/-/devices" \
  | jq -r --arg h "$TS_HOSTNAME" '.devices[] | select(.hostname == $h) | .id'); do
  curl -sL -X DELETE "$PROXY/api/v2/device/$did" >/dev/null
done

# Generate single-use ephemeral auth key (tag:dev grants tailnet access)
TS_AUTHKEY=$(curl -sL -X POST "$PROXY/api/v2/tailnet/-/keys" \
  -H "Content-Type: application/json" \
  -d '{"capabilities":{"devices":{"create":{"reusable":false,"ephemeral":true,"preauthorized":true,"tags":["tag:dev"]}}}}' \
  | jq -r '.key')

# Start tailscaled (pre-installed on exeuntu) — sudo since the script runs as exedev
sudo tailscaled >/dev/null 2>&1 &
sleep 2
sudo tailscale up --ssh --accept-dns --hostname="$TS_HOSTNAME" --authkey="$TS_AUTHKEY"

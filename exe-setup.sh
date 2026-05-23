#!/bin/bash
# exe.dev default setup script — runs at first boot on every new VM.
# Starts Tailscale immediately, then installs dotfiles in the background.
# Secrets never touch VM disk: auth key is generated per-boot via the
# tailscale-api HTTP proxy integration (exe.dev injects the bearer token).

PROXY=https://tailscale-api.int.exe.xyz
TS_HOSTNAME=$(hostname)

# Delete stale Tailscale nodes with this hostname (prevents -2 suffix)
for did in $(curl -sL "$PROXY/api/v2/tailnet/-/devices" \
  | jq -r --arg h "$TS_HOSTNAME" '.devices[] | select(.hostname == $h) | .id'); do
  curl -sL -X DELETE "$PROXY/api/v2/device/$did"
done

# Generate single-use ephemeral auth key
TS_AUTHKEY=$(curl -sL -X POST "$PROXY/api/v2/tailnet/-/keys" \
  -H "Content-Type: application/json" \
  -d '{"capabilities":{"devices":{"create":{"reusable":false,"ephemeral":true,"preauthorized":true,"tags":["tag:dev"]}}}}' \
  | jq -r '.key')

# Start Tailscale immediately (tailscaled is pre-installed on exeuntu)
# Needs sudo — setup script runs as exedev, not root.
sudo tailscaled &
sleep 2
sudo tailscale up --ssh --accept-dns --hostname="$TS_HOSTNAME" --authkey="$TS_AUTHKEY"

# Install dotfiles
curl -fsSL https://raw.githubusercontent.com/kylelundstedt/dotfiles/master/install.sh \
  | TS_AUTHKEY="$TS_AUTHKEY" TS_HOSTNAME="$TS_HOSTNAME" bash

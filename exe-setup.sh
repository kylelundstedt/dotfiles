#!/bin/bash
# exe.dev default-setup-script — fetched at first boot of every new VM.
# Registered via:
#   ssh exe.dev "defaults write dev.exe new.setup-script \
#     'curl -fsSL https://raw.githubusercontent.com/kylelundstedt/dotfiles/master/exe-setup.sh | bash'"
#
# install.sh's setup_tailscale has the same proxy/auth-key logic and is the
# fallback if this script is invoked standalone (e.g. on a non-exe.dev VM).
# This script exists to bring Tailscale up FAST (~18s) so the VM is reachable
# by short name before the full dotfiles install (~60s) completes.
#
# Secrets never touch VM disk: the auth key is minted per-boot via the
# tailscale-api HTTP proxy integration (exe.dev injects the bearer token).

set -e

PROXY=https://tailscale-api.int.exe.xyz
TS_HOSTNAME=$(hostname)

# Delete stale Tailscale nodes with this hostname (prevents -2 suffix on rebuild)
for did in $(curl -sL "$PROXY/api/v2/tailnet/-/devices" \
  | jq -r --arg h "$TS_HOSTNAME" '.devices[] | select(.hostname == $h) | .id'); do
  curl -sL -X DELETE "$PROXY/api/v2/device/$did" >/dev/null
done

# Generate single-use ephemeral auth key (tag:dev grants tailnet access used
# by ssh_config's Match exec block on every client machine)
TS_AUTHKEY=$(curl -sL -X POST "$PROXY/api/v2/tailnet/-/keys" \
  -H "Content-Type: application/json" \
  -d '{"capabilities":{"devices":{"create":{"reusable":false,"ephemeral":true,"preauthorized":true,"tags":["tag:dev"]}}}}' \
  | jq -r '.key')

# Start tailscaled (pre-installed on exeuntu) — sudo since the script runs as exedev
sudo tailscaled >/dev/null 2>&1 &
sleep 2
sudo tailscale up --ssh --accept-dns --hostname="$TS_HOSTNAME" --authkey="$TS_AUTHKEY"

# Hand off to dotfiles install (self-bootstraps the repo clone). install.sh's
# setup_tailscale will see `tailscale status` succeed and skip its own bootstrap.
curl -fsSL https://raw.githubusercontent.com/kylelundstedt/dotfiles/master/install.sh \
  | TS_AUTHKEY="$TS_AUTHKEY" TS_HOSTNAME="$TS_HOSTNAME" bash

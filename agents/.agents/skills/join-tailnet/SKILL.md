---
name: join-tailnet
description: Join an exe.dev VM to the Tailscale tailnet on demand. SSHes in over *.exe.xyz, ensures tailscaled is running, and runs tailscale up with a one-use key minted via the tailscale-api proxy.
---

# Join Tailnet

Joins an exe.dev VM to the IV Tailscale tailnet. The VM must have
the `tailscale-api` integration attached (use `--tag=iv` at creation).

## Usage

The user provides a VM name (e.g. `iv-gitlake`). The skill SSHes in over
the exe.dev edge and runs two commands on the VM.

## Steps

1. **SSH into the VM over `*.exe.xyz`** (one attempt, `ConnectTimeout=30`).
2. **Run the join commands** on the VM:

```bash
ssh -o ConnectTimeout=30 <vm>.exe.xyz 'bash -s' <<'REMOTE'
set -euo pipefail
# Stock exeuntu ships tailscaled DISABLED (iv-image enabled it); enable+start
# either way so `tailscale up` can reach the local daemon.
sudo systemctl enable --now tailscaled
KEY=$(curl -fsSL -X POST https://tailscale-api.int.exe.xyz/api/v2/tailnet/-/keys \
  -H "Content-Type: application/json" \
  -d '{"capabilities":{"devices":{"create":{"reusable":false,"ephemeral":true,"preauthorized":true,"tags":["tag:dev"]}}}}' \
  | jq -r .key)
sudo tailscale up --ssh --accept-dns --hostname="$(hostname)" --authkey="$KEY"
tailscale status
REMOTE
```

3. **Verify** the VM appears in `tailscale status` output.

After it joins, use `ssh <vm>` (Tailscale SSH) for everything else.

## Prerequisites

- The VM must be created with `--tag=iv` so the `tailscale-api` integration is attached.
- `tailscaled` is enabled+started by the join command above — stock exeuntu ships it disabled, so don't assume it's already running.

## SSH discipline

- **One SSH attempt at a time.** Never launch parallel SSH to `*.exe.xyz`.
- If SSH fails, wait 30-60s before one more attempt.

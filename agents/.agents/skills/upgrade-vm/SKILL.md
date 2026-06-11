---
name: upgrade-vm
description: Upgrade an iv-image exe.dev VM to a newer image version. Destroys and recreates the VM, deletes the stale tailnet node, and rejoins. Wipes the VM's local disk.
---

# Upgrade VM

Upgrades an exe.dev VM to a newer iv-image by destroying and recreating it.
This **wipes the VM's local disk** -- it reprovisions, it does not migrate state.

## Usage

The user provides:
- **VM name** (e.g. `iv-gitlake`) -- required
- **Target image** (e.g. `iv-image:2.1.0` or `iv-image:2`) -- defaults to `iv-image:2` (latest major)
- **Tag** -- defaults to `iv`
- **Integrations** to attach after creation (e.g. `github-iv-cmg-iv-gitlake`) -- optional

## Steps

Run these sequentially. **One SSH command at a time** -- never parallel SSH to exe.dev.

### 1. Confirm with the user

This is destructive. Confirm the VM name and that wiping its disk is acceptable.

### 2. Delete the stale Tailscale node

The old VM's tailnet node must be deleted before the new one joins, otherwise
the new VM gets a `-1` suffix. Use the Tailscale API from the Mac (which has
the real API credential via 1Password):

```bash
# Get the Tailscale API key
TS_API_KEY=$(op read "op://Employee/Tailscale - API Key/credential" --account industryvault.1password.com)

# Find the node ID by hostname
NODE_ID=$(curl -fsSL -H "Authorization: Bearer $TS_API_KEY" \
  https://api.tailscale.com/api/v2/tailnet/-/devices \
  | jq -r '.devices[] | select(.hostname == "<vm>") | .id')

# Delete the node
curl -fsSL -X DELETE -H "Authorization: Bearer $TS_API_KEY" \
  "https://api.tailscale.com/api/v2/device/$NODE_ID"
```

### 3. Destroy the old VM

```bash
ssh -o ConnectTimeout=30 exe.dev rm <vm>
```

### 4. Remove stale SSH state

```bash
# Remove old host key from known_hosts (the *.exe.xyz wildcard covers it,
# but the tailnet hostname may have a cached key)
ssh-keygen -R <vm> 2>/dev/null || true

# Kill any stale SSH multiplexed connection
ssh -O exit <vm> 2>/dev/null || true
ssh -O exit <vm>.exe.xyz 2>/dev/null || true
```

### 5. Create the new VM

```bash
ssh -o ConnectTimeout=30 exe.dev new \
  --image=iv-registry.exe.xyz:5000/<image> \
  --name=<vm> --tag=<tag>
```

If the user specified integrations, attach them:

```bash
ssh -o ConnectTimeout=30 exe.dev integrations attach <integration> vm:<vm>
```

### 6. Wait for the VM to boot

Wait ~20s, then try one SSH with `ConnectTimeout=30`:

```bash
sleep 20
ssh -o ConnectTimeout=30 <vm>.exe.xyz echo "VM is up"
```

If it fails, wait 30-60s and try once more.

### 7. Rejoin the tailnet

Use the `join-tailnet` skill (or run the commands directly):

```bash
ssh -o ConnectTimeout=30 <vm>.exe.xyz 'bash -s' <<'REMOTE'
set -euo pipefail
KEY=$(curl -fsSL -X POST https://tailscale-api.int.exe.xyz/api/v2/tailnet/-/keys \
  -H "Content-Type: application/json" \
  -d '{"capabilities":{"devices":{"create":{"reusable":false,"ephemeral":true,"preauthorized":true,"tags":["tag:dev"]}}}}' \
  | jq -r .key)
sudo tailscale up --ssh --accept-dns --hostname="$(hostname)" --authkey="$KEY"
tailscale status
REMOTE
```

### 8. Verify

```bash
tailscale status | grep <vm>
```

## SSH discipline

- **One SSH attempt at a time.** Never launch parallel SSH to `*.exe.xyz` or `exe.dev`.
- Wait for each command to complete before starting the next.
- If SSH fails, wait 30-60s before one more attempt.

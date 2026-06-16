---
name: upgrade-vm
description: Upgrade an IV exe.dev VM's software layer by re-provisioning it in place at a newer iv-image commit (no recreate, no disk wipe). Falls back to a full destroy/recreate only when a fresh disk or a base change is actually required.
---

# Upgrade VM

IV VMs run **stock `boldsoftware/exeuntu`** (which keeps Shelley) and get their
tooling from `provision-iv.sh` in the `iv-image` repo. So "upgrading" a VM is
normally just **re-running the provisioner at a newer commit** — in place, no
recreate, no disk wipe, no tailnet churn.

Full destroy/recreate is now the exception, needed only when you genuinely want a
fresh disk or the exe.dev-managed base has changed in a way re-provisioning can't
pick up.

## Path A — Re-provision in place (default)

The user provides the **VM name** and optionally a **target tag/sha** of the
`iv-image` repo (defaults to the latest on the default branch).

**One SSH command at a time** — never parallel SSH to `*.exe.xyz` or `exe.dev`.

```bash
ssh -o ConnectTimeout=30 <vm>.exe.xyz "cd ~/iv-image && git fetch --tags --quiet \
  && git checkout <tag-or-sha-or-branch> && git pull --ff-only --quiet 2>/dev/null; \
  ~/iv-image/provision-iv.sh"
```

This re-pins tools and re-installs the vendored skills + agent config, and
rewrites `~/iv-provision.lock`. Verify:

```bash
ssh -o ConnectTimeout=30 <vm>.exe.xyz "cat ~/iv-provision.lock"
```

If `~/iv-image` doesn't exist yet (older VM), clone it first — see `bootstrap.md`.

## Path B — Full destroy + recreate (only when required)

This **wipes the VM's local disk** — it reprovisions, it does not migrate state.
Use only when Path A can't deliver the change.

Run sequentially. **One SSH command at a time.**

### 1. Confirm with the user

This is destructive. Confirm the VM name and that wiping its disk is acceptable.

### 2. Delete the stale Tailscale node

The old VM's tailnet node must be deleted before the new one joins, otherwise the
new VM gets a `-1` suffix. Use the Tailscale API from the Mac (which has the real
API credential via 1Password):

```bash
TS_API_KEY=$(op read "op://Employee/Tailscale - API Key/credential" --account industryvault.1password.com)
NODE_ID=$(curl -fsSL -H "Authorization: Bearer $TS_API_KEY" \
  https://api.tailscale.com/api/v2/tailnet/-/devices \
  | jq -r '.devices[] | select(.hostname == "<vm>") | .id')
curl -fsSL -X DELETE -H "Authorization: Bearer $TS_API_KEY" \
  "https://api.tailscale.com/api/v2/device/$NODE_ID"
```

### 3. Destroy the old VM

```bash
ssh -o ConnectTimeout=30 exe.dev rm <vm>
```

### 4. Remove stale SSH state

```bash
ssh-keygen -R <vm> 2>/dev/null || true
ssh -O exit <vm> 2>/dev/null || true
ssh -O exit <vm>.exe.xyz 2>/dev/null || true
```

### 5. Create the new VM (stock exeuntu — no --image)

```bash
ssh -o ConnectTimeout=30 exe.dev new --name=<vm> --tag=<tag>
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

### 7. Rejoin the tailnet + provision

Use the `join-tailnet` skill, then run the full bring-up from `bootstrap.md`
(attach `github-kylelundstedt-iv-image`, clone, `provision-iv.sh`, then clone the
work repo + `provision-docsite`).

### 8. Verify

```bash
tailscale status | grep <vm>
ssh -o ConnectTimeout=30 <vm>.exe.xyz "cat ~/iv-provision.lock"
```

## SSH discipline

- **One SSH attempt at a time.** Never launch parallel SSH to `*.exe.xyz` or `exe.dev`.
- Wait for each command to complete before starting the next.
- If SSH fails, wait 30-60s before one more attempt.

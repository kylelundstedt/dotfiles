---
name: join-tailnet
description: Join an exe.dev VM to the Tailscale tailnet on demand. Attaches the tailscale-api integration for the duration of the join, mints a one-use ephemeral key through the proxy, runs tailscale up, and detaches again.
---

# Join Tailnet

Joins an exe.dev VM to the IV Tailscale tailnet.

## Usage

Run the helper. It does everything, including attaching and detaching the
credential:

```bash
~/.agents/skills/join-tailnet/join-tailnet.sh <vm-name>
```

Then verify the VM appears in `tailscale status`. After it joins, use
`ssh <vm>` (Tailscale SSH) for everything else.

## Why the script, and not the raw commands

`tailscale-api` is **no longer attached to VMs by default** (changed
2026-07-28). It used to be `auto:all`, which meant every VM — including the
public-facing `rss-feed` and `telnyx-vm` — could mint tailnet auth keys, remove
nodes, and edit ACLs at any time. Verified from `rss-feed`: a token exchange
against the proxy returned HTTP 200.

The script now:

1. Checks whether `tailscale-api` is already attached to the VM. If so, it
   leaves the attachment exactly as found and skips step 4.
2. Attaches `tailscale-api` to `vm:<name>`.
3. SSHes in over `*.exe.xyz`, ensures `tailscaled` is running, exchanges an
   OAuth token through the proxy, mints a one-use ephemeral preauthorized key
   against the public API, and runs `tailscale up`.
4. Detaches `tailscale-api` on exit — via a trap that fires on error and
   interrupt, not only on success.

So the authority exists only while it is being used. If a detach ever fails the
script warns loudly; `ssh exe.dev integrations list` will show the stray
`vm:` attachment.

**Do not hand-run the old inline `curl` commands.** Without an attachment the
token exchange returns no `access_token`, and the natural next move — attaching
`tailscale-api` by hand and forgetting to detach — is exactly the standing
authority this change removed.

## Prerequisites

- The VM exists and is reachable at `<vm>.exe.xyz`.
- `curl` and `jq` are present on the VM (stock exeuntu and iv-image both have
  them; a slim/exeslim base may not — check before relying on this skill there).
- `tailscaled` is enabled and started by the script. Stock exeuntu ships it
  **disabled**, so don't assume it is already running.
- You are running from `klundstedt-mini`, which owns exe.dev control-plane
  mutations.

## Notes

- Keys are minted `ephemeral:true`, so a node that goes offline long enough is
  removed from the tailnet and must be re-joined by re-running this script.
- `--tag=iv` at VM creation is **no longer sufficient or required** for tailnet
  joining. It still governs other `tag:iv` integrations.

## SSH discipline

- **One SSH attempt at a time.** Never launch parallel SSH to `*.exe.xyz`.
- If SSH fails, wait 30–60s before one more attempt.

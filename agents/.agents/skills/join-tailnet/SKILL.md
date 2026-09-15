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

`api-tailscale` (formerly `tailscale-api`) is attached in **two lanes** (settled
2026-09-15; the contract lives in iv-provision `tailnet.md`):

- **Private dev VMs** carry a standing grant through the exe.dev tag `tailnet`,
  because the browser-driven `create-vm` skill can only fix things at `new`
  time (its token cannot attach or detach). A dev VM is private, so this is the
  same exposure as the VM itself.
- **Anything internet-facing, and every prod-lane deployment target**, gets a
  time-boxed per-VM grant — `ssh exe.dev integrations attach api-tailscale
vm:<vm> --for 30m` — never the tag. This is what the 2026-07-28 remediation
  was about: `auto:all` had put key-minting on the public-facing `rss-feed`
  and `telnyx-vm` (token exchange from `rss-feed` returned HTTP 200), and the
  `tailnet` tag had quietly put it back on them between 2026-08-19 and
  2026-09-15. Removed again 2026-09-15 (`tag -d <vm> tailnet` on the four
  public VMs).

This script is the third path — a **one-off join from the mini** for a VM that
has neither: it attaches for the duration of the join and detaches after.

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
  For a long-lived appliance that must survive outages, run with
  `IV_TAILSCALE_EPHEMERAL=false` (added 2026-09-15 for the AgentsView
  collector rebuild): the node then persists, and retiring the VM must delete
  the node in the admin console (iv-provision `retiring.md` §5).
- `--tag=iv` at VM creation is **no longer sufficient or required** for tailnet
  joining. It still governs other `tag:iv` integrations.
- **Prod-lane images self-join at boot (since exeslim 2026-08-23).** The
  `exeslim` (not `exeslim-dev`) image ships `iv-tailnet-join.service`: at first
  boot it probes the `api-tailscale` proxy and, if attached, mints a
  **`tag:prod`** key and joins. `api-tailscale` is attached to the exe.dev tag
  `tailnet`, so `new --tag=tailnet` on an exeslim VM means it is on the tailnet
  as `tag:prod` seconds after boot, and this helper then exits early ("already
  on the tailnet"). To get `tag:dev` on such a VM: `sudo tailscale logout` on
  it, then run this helper. Seen on `iv-llm-relay` 2026-09-15.
- Prod-lane nodes are minted **non-ephemeral** since exeslim 2026-09-15, so an
  appliance never needs the API after its first boot; an older ephemeral prod
  node that gets reaped after a long outage needs a 30-minute attach and
  `systemctl start iv-tailnet-join` over the `.exe.xyz` edge (or this script,
  which would make it `tag:dev`).

## SSH discipline

- **One SSH attempt at a time.** Never launch parallel SSH to `*.exe.xyz`.
- If SSH fails, wait 30–60s before one more attempt.

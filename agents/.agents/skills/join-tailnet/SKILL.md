---
name: join-tailnet
description: Bring an exe.dev VM onto IV's Tailscale tailnet on demand. Use when an iv-image VM (>= 2.0.0) needs to join the tailnet — iv-image no longer auto-joins at boot. SSHes in over *.exe.xyz and runs `tailscale up` with a one-use key minted through the exe.dev tailscale-api proxy.
---

# join-tailnet

iv-image `>= 2.0.0` does **not** auto-join the tailnet. A fresh VM is reachable
only over the exe.dev edge (`ssh <vm>.exe.xyz`). Use this skill to put it on IV's
tailnet when you actually want it there.

## Use it

```bash
~/.agents/skills/join-tailnet/join-tailnet.sh <vm-name>
```

`<vm-name>` is the exe.dev VM name (the `--name` you passed to `ssh exe.dev new`),
not a `.exe.xyz` or `.ts.net` FQDN.

After it succeeds, reach the VM with `ssh <vm>` (Tailscale SSH) for everything
else — faster, no exe.dev edge rate limit, agent forwarding.

## What it does

1. SSH into `<vm>.exe.xyz` (edge path — no tailnet needed to bootstrap the tailnet).
2. If the VM is already `Running` on the tailnet, print status and exit (idempotent).
3. Otherwise POST to `https://tailscale-api.int.exe.xyz/api/v2/tailnet/-/keys` to
   mint a one-use, ephemeral, preauthorized `tag:dev` auth key. exe.dev injects
   the real Tailscale API credential at the proxy layer — the VM never sees it.
4. `sudo tailscale up --ssh --accept-dns --hostname=$(hostname) --authkey=<key>`.

## Preconditions

- VM created from iv-image `>= 2.0.0` (ships `tailscaled` enabled, plus `curl`/`jq`).
- VM created with `--tag=iv` so the `tailscale-api` integration is attached — the
  mint step needs it. Without it, the script exits with a clear error.

## Overrides

- `IV_TAILSCALE_TAG` — tailnet tag (default `tag:dev`).
- `IV_TAILSCALE_API_URL` — proxy base URL (default `https://tailscale-api.int.exe.xyz`).

## Notes

- The minted key is short-lived, non-reusable, and tagged; no Tailscale secret is
  written to the VM.
- Reusing a VM name before its old ephemeral node is reaped can produce a
  MagicDNS `-1` suffix. This skill does not delete stale nodes (it holds no
  device-delete authority) — clean those from an admin context. See `tailnet.md`
  in the iv-image repo.

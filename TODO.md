# TODO

## Devbox image (reproducible dev environment)

### Build

- [ ] Determine full tool list and versions (driven by GitLake needs)
- [ ] Build `image/Dockerfile` with pinned tool versions, `klundstedt` user
- [ ] Build `image/build.sh` for local builds via `container build`

### Deploy per backend

- [ ] Apple Container: update `container` to use devbox image instead of `ubuntu:25.04`
- [ ] exe.dev: use devbox image via `new --image`
- [ ] Sprite: wait for checkpoint forking, then create golden sprite from devbox (no custom image support yet)

### Validate

- [ ] Test end-to-end on Apple Container
- [ ] Test end-to-end on exe.dev
- [ ] Test end-to-end on Sprite (once checkpoint forking lands)

## Secrets on remote VMs

Solved:
- GitHub clone/push/signing — SSH agent forwarding via Tailscale (2026-04-12)

Requires Mac-side `op read` (biometric) + env var passing:
- `TS_AUTHKEY` — needed once at VM creation to join the tailnet
- Agents can't resolve this autonomously (Touch ID required)

Not yet solved for VMs:
- MCP servers — OAuth (MotherDuck, Tigris) needs a browser; GitHub MCP needs PATs from 1Password
- Project-specific secrets (API keys, database creds, AWS credentials)
- `op` CLI is installed on VMs but has no account configured

Open items:
- [ ] Evaluate Tailscale OAuth clients for reusable, non-expiring auth keys (removes `op read` dependency for `TS_AUTHKEY`)
- [ ] Decide on 1Password strategy for VMs:
  - Mac-side resolution (current) — simple, works for test/ephemeral VMs
  - Service Accounts — one `OP_SERVICE_ACCOUNT_TOKEN` env var, needs `op` on each VM
  - Connect Server on tailnet — one persistent VM runs Docker containers, other VMs query via HTTP + `OP_CONNECT_TOKEN`. No `op` needed on clients. Worth it when VMs need autonomous secret access (long-lived devboxes, unattended agents).

## Apple Containers

- [ ] `container create` broken in 0.11.0 — rootfs never provisioned (apple/container#1398). Workaround: `container run -d`. Skill already uses the workaround.

## Done (2026-04-12)

- [x] Unified SSH agent forwarding across all three VM platforms (Apple Containers, exe.dev, Sprites)
- [x] Login-time commit signing hook in .zshrc (moved from install-time)
- [x] SSH hostname canonicalization for MagicDNS short names
- [x] Fixed Tailscale macOS detection (`brew list --formula` vs `brew list`)
- [x] Switched Tigris skills to `tigrisdata/tigris-agents-plugins`
- [x] Added Archil CLI (Linux) and Archil.app (macOS --apps)
- [x] Added flux-markdown QuickLook extension to Brewfile
- [x] Updated README and CLAUDE.md with current skills, flags, and architecture

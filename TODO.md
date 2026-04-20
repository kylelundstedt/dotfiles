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

Strategy decided 2026-04-16: secrets live in 1Password (source of truth), delivered to VMs as `.env` files via scripted scp over Tailscale. No `op` CLI or service accounts needed on VMs.

Solved:
- GitHub clone/push/signing — SSH agent forwarding via Tailscale
- `TS_AUTHKEY` — passed as env var at VM creation (Mac-side biometric, one-time per VM)

Not yet solved:
- MCP servers — OAuth (MotherDuck, Tigris) needs a browser; GitHub MCP needs PATs

To do:
- [ ] Set up 1P Environments per project as the organized source of truth for project secrets
- [ ] Build `provision-secrets.sh` — reads from 1P Environments on Mac, generates `.env`, pushes to VMs via scp
- [ ] Evaluate Tailscale OAuth clients for reusable, non-expiring auth keys (removes biometric dependency for `TS_AUTHKEY`)

## Apple Containers

- [ ] `container create` broken in 0.11.0 — rootfs never provisioned (apple/container#1398). Workaround: `container run -d`. Skill already uses the workaround.

## Done (2026-04-20)

- [x] Added Snowflake CLI (`snow`) via `uv tool install snowflake-cli` in install.sh

## Done (2026-04-12)

- [x] Unified SSH agent forwarding across all three VM platforms (Apple Containers, exe.dev, Sprites)
- [x] Login-time commit signing hook in .zshrc (moved from install-time)
- [x] SSH hostname canonicalization for MagicDNS short names
- [x] Fixed Tailscale macOS detection (`brew list --formula` vs `brew list`)
- [x] Switched Tigris skills to `tigrisdata/tigris-agents-plugins`
- [x] Added Archil CLI (Linux) and Archil.app (macOS --apps)
- [x] Added flux-markdown QuickLook extension to Brewfile
- [x] Updated README and CLAUDE.md with current skills, flags, and architecture

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

> Re-evaluated 2026-04-21. exe.dev's `ghcr.io/boldsoftware/exeuntu` (Ubuntu 24.04, kitchen-sink apt list, systemd) is a usable public base image — if we revive this plan, consider extending exeuntu rather than building from scratch. Sprite still lacks custom-image support and checkpoint forking; no roadmap signal since Jan 2026. Decision: keep waiting, not urgent.

## Secrets on remote VMs

Strategy (revised 2026-04-21): 1Password Environments per project; `op` CLI on VM authenticated with a scoped service-account token; secrets injected at runtime via `op run --env-file=<id> -- cmd`. No plaintext `.env` files on disk, no bespoke provisioning script, reactive to 1P changes. The SA token is the one bootstrap secret — provisioned to the VM at creation time via env var (same pattern as `TS_AUTHKEY`).

Solved:

- GitHub clone/push/signing — SSH agent forwarding via Tailscale
- `TS_AUTHKEY` — passed as env var at VM creation (Mac-side biometric, one-time per VM)

Not yet solved:

- MCP server OAuth (MotherDuck, Tigris) — first-time browser flow can't be injected; needs separate strategy (port-forward Mac browser to VM, or per-machine auth)

To do:

- [ ] Create per-project service account in 1P with read-only access to that project's vault
- [ ] Extend `install.sh` to accept `OP_SERVICE_ACCOUNT_TOKEN` env var; write it to `~/.config/op/sa-token` on VM so `op` auto-authenticates
- [ ] Set up first 1P Environment for a real project to validate the `op run --env-file` flow
- [ ] Wire GitHub MCP PAT injection via `op run` at install time (replaces current `op read` on Mac)
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

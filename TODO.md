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
- [ ] Evaluate Tailscale OAuth clients with `auth_keys` + `devices` scopes — gives reusable non-expiring auth keys (removes biometric dependency for `TS_AUTHKEY`) AND programmatic node deletion via `DELETE /api/v2/device/{id}` (removes today's manual ghost-node cleanup in the admin console after every VM teardown)

## Apple Containers

- [ ] `container create` broken in 0.11.0 — rootfs never provisioned (apple/container#1398). Workaround: `container run -d`. Skill already uses the workaround.

## install.sh on bare exe.dev VMs (ubuntu:24.04)

Decision (2026-04-23): root stays root on exe.dev. Don't try to create a `klundstedt` user to match Apple Containers — Sprite is locked into `/home/sprite/` so the three-platform path can't be unified anyway. Convention: use `~`/`$HOME` in any code that needs to reference the home dir; per-VM users/paths stay platform-specific (AC = `/home/klundstedt`, Sprite = `/home/sprite`, exe.dev = `/root`).

- [ ] `snowflake-cli` install via `uv tool install` failed on fresh ubuntu:24.04 VM. Investigate root cause (Python toolchain not yet available?).
- [ ] `fnm` not available after CLI tools step → Node setup skipped → `npx` missing → skill installation skipped. Either install fnm earlier or fall back to a different node bootstrap.

Done (2026-04-23):

- [x] Added `cron` to apt deps (was missing on ubuntu:24.04, caused install.sh to abort at the `@reboot tailscaled` crontab call before Tailscale auth ran)
- [x] Dropped the Linux-side `op read` fallback for `TS_AUTHKEY` — never reachable on a VM (op installed but not signed in). macOS fallback retained since op is signed into industryvault there.

## Per-project VM helper (`exe-up`)

One-command equivalent of today's per-VM bootstrap dance: `exe-up <vm-name> <github-org/repo>` creates the exe.dev VM, waits for ready, installs curl, runs `install.sh` with `TS_AUTHKEY`/`TS_HOSTNAME`, clones the repo via Tailscale-forwarded SSH, and adds the Zed `ssh_connections` entry. Worth doing — already at 5+ project VMs and growing one-per-repo.

**Blocked on (do these first):**

- [ ] Tailscale OAuth client with `devices` scope (see "Secrets on remote VMs"). Without programmatic node deletion, `--rebuild` would leave ghost nodes on every teardown — same friction we hit twice today. The helper without rebuild is half-useful; with it, that's the whole UX.
- [ ] Sharing-across-folks story for secrets. Today's bootstrap path hardcodes `op://Employee/Tailscale - iv-internal-dev/credential` and the industryvault account. The helper needs to accept `TS_AUTHKEY` from env first, fall back to `op read` only as convenience for users with the same 1P setup, and document both paths in the exe-dev skill.

**Design once unblocked:**

- Idempotent by default — detect each piece (VM exists, Tailscale up, repo cloned, Zed bookmark present) and only do the missing parts. Safe to re-run after partial failure (which we needed several times today). Same purpose + fully set up → no-op with status. Same purpose + partial state → finish missing steps. Name collision + different purpose → bail with error.
- `--rebuild` flag (with confirmation) for clean slate, only useful once ghost-node cleanup is automatic.
- Lives at `~/.local/bin/exe-up` (stowable via existing pattern), not as a skill.

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

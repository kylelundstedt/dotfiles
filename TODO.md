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
- MCP server OAuth (MotherDuck, Tigris, Readwise) — Mac's `~/.ssh/config` carries `LocalForward 8765 localhost:8765` for `*.exe.xyz` only (install.sh, 2026-05-17). `User root` covers both `*.exe.xyz` and `*.<tailnet>.ts.net` so `ssh <vm>` still defaults to root, but the OAuth port forward is intentionally scoped to the lobby hostname so routine Tailscale SSH (incl. Zed's persistent remote-server connection) doesn't race for port 8765. For OAuth, use `ssh <vm>.exe.xyz` explicitly. Verified end-to-end on `gitlake` with Tigris. Per-VM token cache; do one OAuth at a time per VM.

To do:

- [ ] Create per-project service account in 1P with read-only access to that project's vault
- [ ] Extend `install.sh` to accept `OP_SERVICE_ACCOUNT_TOKEN` env var; write it to `~/.config/op/sa-token` on VM so `op` auto-authenticates
- [ ] Set up first 1P Environment for a real project to validate the `op run --env-file` flow
- [ ] Wire GitHub MCP PAT injection via `op run` at install time (replaces current `op read` on Mac). Same change unblocks Codex GitHub MCPs (github-home, github-work) — Codex disallows inline bearer tokens in `config.toml` (only `bearer_token_env_var`), so it needs a `codex` wrapper that sources PATs via `op run --env-file=...` at exec time, or a 0600-mode cache file sourced from shell init.
- [ ] Evaluate Tailscale OAuth clients with `auth_keys` + `devices` scopes — gives reusable non-expiring auth keys (removes biometric dependency for `TS_AUTHKEY`) AND programmatic node deletion via `DELETE /api/v2/device/{id}` (removes today's manual ghost-node cleanup in the admin console after every VM teardown)

## Apple Containers

- [ ] `container create` broken in 0.11.0 — rootfs never provisioned (apple/container#1398). Workaround: `container run -d`. Skill already uses the workaround.

## install.sh on bare exe.dev VMs (ubuntu:24.04)

Decision (2026-04-23): root stays root on exe.dev. Don't try to create a `klundstedt` user to match Apple Containers — Sprite is locked into `/home/sprite/` so the three-platform path can't be unified anyway. Convention: use `~`/`$HOME` in any code that needs to reference the home dir; per-VM users/paths stay platform-specific (AC = `/home/klundstedt`, Sprite = `/home/sprite`, exe.dev = `/root`).

- [ ] `snowflake-cli` install via `uv tool install` failed on fresh ubuntu:24.04 VM. Investigate root cause (Python toolchain not yet available?).
- [ ] `fnm` not available after CLI tools step → Node setup skipped → `npx` missing → skill installation skipped. Either install fnm earlier or fall back to a different node bootstrap.

Done (2026-05-01):

- [x] Switched no-systemd branch to kernel-mode tailscaled (dropped `--tun=userspace-networking` from the `nohup` start and `@reboot` cron line). Verified on exe.dev: `/dev/net/tun` is exposed, `tailscale0` interface comes up. Migrated existing exe.dev VMs (`dotfiles`, `gitlake`, `gse-lld`) in place; node identities preserved (no ghosts). Apple Container behavior on this branch not retested.

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

## Consolidate on exe.dev (Sprite + Apple Containers on back burner)

Decision (2026-05-01): focus the dev-VM stack on exe.dev. Phase 1 (kernel-mode Tailscale on exe.dev, plain `ssh <vm>` works VM-to-VM) shipped same day. Phases below queued.

### Phase 2 — Reorient docs/skills

- [ ] Demote `apple-containers` and `sprites-dev` in root `CLAUDE.md` from peer recommendations to "alternative paths, not actively maintained."
- [ ] Same edit in `agents/.agents/AGENTS.md`.
- [ ] README touch-up if it lists all three as equals.
- [ ] Leave the skill files themselves on disk — still functional, just no longer the recommended path.

### Phase 3 — Unblock exe.dev-specific work

- [ ] Build `exe-up` per-project helper (see "Per-project VM helper" above) — was blocked partly on cross-platform symmetry, no longer is.
- [ ] Service-account-token / `op run --env-file` flow (see "Secrets on remote VMs") — drop the cross-platform constraints and just make it work on exe.dev.

### Phase 4 — Cleanup (low priority)

- [ ] Mark `test-install.sh`'s Apple Container and Sprite paths informational (don't fail CI).
- [ ] Drop the platform-specific home-dir convention from "install.sh on bare exe.dev VMs" — irrelevant once exe.dev (`/root`) is the only target.
- [ ] Consider archiving `sprites-dev` skill to a `legacy/` folder. Not urgent.

### Upgrade path for existing VMs (one-time, manual)

`install.sh` change makes new VMs come up in kernel mode automatically and self-heals the @reboot crontab. Existing VMs (`gitlake`, `gse-lld`, `dotfiles`) keep running in their current mode until tailscaled restarts. To switch a running VM to kernel mode without rebooting:

```bash
ssh root@<vm>.exe.xyz 'pkill -x tailscaled; sleep 2; nohup tailscaled >/var/log/tailscaled.log 2>&1 &'
```

Use lobby SSH (`*.exe.xyz`), not Tailscale SSH — restarting tailscaled on the destination drops any in-flight Tailscale SSH session. Safe to re-run.

## Tailscale ACL

VM-to-VM SSH unblocked 2026-05-01 with broad `tag:dev` → `tag:dev` rules (network grant + Tailscale SSH, root included). Single compromised dev VM = root on all of them. Acceptable now (small handful of personal VMs) but worth tightening.

- [ ] Drop `root` from the `tag:dev` → `tag:dev` SSH `users` list, force a non-root account.
- [ ] Or split tags: only mesh-connect VMs that need it (e.g. `tag:dev-mesh`) and keep solo VMs on plain `tag:dev` with no peer access.
- [ ] Or port-restrict the network grant: replace `"ip": ["*"]` with explicit ports (`*:22` plus whatever else cross-VM traffic actually uses).

## Basic Memory (evaluation)

Cross-AI / multi-machine persistent memory via Basic Memory (basicmachines-co). Claude Code's built-in auto-memory is per-machine, not synced, and Claude-only; Codex has its own native memory. Basic Memory could fill both gaps via MCP. Per-project cloud routing (v0.21.0) lets one client mount a mix of local and cloud-routed projects.

- [ ] Pick hosting model: AGPL local (`uv tool install basic-memory`) vs Basic Memory Cloud ($14.25/mo beta-discounted) vs Teams (`teams-beta` milestone 90% complete in repo, not yet launched per public docs)
- [ ] Run a small trial on klundstedt-mini against one project (suggested: a contained client engagement) and evaluate over 1–2 weeks before wiring into `install.sh`
- [ ] If kept: install on all machines via install.sh; decide sync model for `~/basic-memory` across MBP/Mini/exe.dev VMs (git-tracked dir aligns with existing dotfiles sync pattern)
- [ ] Document policy in `agents/.agents/AGENTS.md` distinguishing Basic Memory vs Claude Code's auto-memory vs Codex native memory — when to write which
- [ ] Install companion skills (`basicmachines-co/basic-memory-skills`) — memory-notes, memory-reflect, memory-defrag, memory-research, etc.

### IV Products architecture (depends on Basic Memory adoption decision)

Per `gitlake/iv/iv_products.md`, IV Datasets surface a "per-dataset Data Product MCP server" alongside the query MCP. Basic Memory's per-project cloud routing is a natural fit for the semantic layer (schema, data dictionary, harmonization rules, restatement history, sample queries) — one Basic Memory project per (client, dataset) tuple, mounted alongside the data-query MCP.

- [ ] Decide storage placement: per-client Archil mount (inherits AVE/GitLake guarantees + "client owns storage" property; loses cloud-routed sync) vs Basic Memory Cloud (multi-machine sync, shareable to client; breaks "client owns storage" unless Teams ships with BYO storage)

## install.sh hygiene

- [ ] Replace swallowed errors in `setup_agents` (`>/dev/null 2>&1 || true` → explicit `echo "[!] X failed"` on non-zero). The silent pattern hid the missing `github-home` MCP on klundstedt-mini for an unknown number of runs before it was diagnosed.
- [ ] Trace and remove the `GITHUB_TOKEN` env var that overrides gh's keyring on klundstedt-mini (likely set in `.zshrc`/`.zshenv`/atuin shell init); low priority

## Done (2026-05-20)

- [x] Zed: removed `agent_servers` ACP block. Anthropic's June 15 billing change stops Claude Pro/Max from covering ACP/agent-panel usage (moves to per-credit pricing at API rates); `claude` CLI in a Zed terminal thread still draws from the Max subscription. Default agentic flow is now CLI (`claude`, `codex`) via Zed terminal threads, preserving subscription value for both providers.
- [x] Zed: cleared `ssh_connections` in tracked file and wired `git update-index --skip-worktree` after stow in `install.sh` so Zed's UI mutations no longer pollute `git status`. Per-machine `ssh_connections` editing stays local without churn.
- [x] install.sh: wire `gh` CLI auth. Browser OAuth on macOS interactive (gh gets its own scoped token, separate from MCP PATs); `op read | gh auth login --with-token` fallback for headless/Linux.
- [x] install.sh: switch Codex CLI install to native binary — `brew install --cask codex` on macOS, native musl tarball from GitHub releases on Linux via `install_github_binary`. npm kept as last-resort fallback. Fixed a corrupt npm install on klundstedt-mini (empty vendor dir → broken `codex` on PATH).
- [x] install.sh: register OAuth MCP servers for Codex (motherduck, tigris, readwise) mirroring Claude Code's set; idempotent via `codex mcp get` to avoid re-OAuth on every install run (Codex eagerly OAuths at add-time, unlike Claude's lazy first-use auth).
- [x] Recovered missing `github-home` Claude MCP on klundstedt-mini — failed silently at a prior install (`op read` returned empty); after PAT rotation in 1P and re-run of `install.sh`, both `github-home` and `github-work` are connected.
- [x] Runtime cleanup on klundstedt-mini: removed stale user-scope `duckdb` MCP entry (pointed at nonexistent `dotfiles/claude/bin/duckdb-mcp`); removed local-scope `MotherDuck` duplicate of the user-scope `motherduck`.

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

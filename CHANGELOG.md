# Changelog

A dated work journal for this repo — completed changes, with rationale and gotchas
that commit messages don't always capture. Newest first. Open work lives in
[TODO.md](TODO.md).

## 2026-06-27

- **klundstedt-mini archive backup → Tigris (done).** `~/archives/` (msgvault email, calendar DuckDB, `speaking-engagements.md`) is inside `$HOME/`, which `backup/tigris-backup.sh` syncs nightly to `tigris:klundstedt-mini-backup` (`bkup:home`) — client-side encrypted via rclone crypt, with nightly Tigris snapshots. No exclude pattern covers `archives/`, so it's fully captured. External-volume archives (aws-s3, box, iphone-backup, messages-store) go to the GLACIER `klundstedt-mini-archive` bucket. Supersedes the original "create bucket + scheduled sync" task.
- **Added `agent_docs/personal-mcp.md`** documenting the `hub-mcp` unified search server, its ingest scripts, and LaunchAgent schedules. Surfaced `hub-mcp` in the README (intro + MCP table). Fixed the `~/archives/calendar-sources/` → `~/archives/calendar/sources/` path in `calendar-refresh.sh`'s comment.

## 2026-06-19

- **Documented klundstedt-mini tailscale upgrade ritual** (README + AGENTS.md). `setup_tailscale` is install-if-missing + restart-on-skew — it never `brew upgrade`s, so formula bumps are manual. Because `tailscaled` runs as a root system daemon, `sudo brew services` taints each keg with root-owned binaries and `brew cleanup` can't remove old kegs: ritual is `brew upgrade tailscale` → `sudo brew services restart tailscale` (clears CLI/daemon skew) → `sudo rm -rf /opt/homebrew/Cellar/tailscale/<old-versions>`. Upgraded this host 1.96.4 → 1.98.5 and verified a fresh `install.sh` run leaves it skew-free.

## 2026-06-11

- **iv-image 2.1.0: baked team agent config.** New `agent/` directory: team AGENTS.md, Claude Code settings.json (SSH guard hook), MCP pre-registration (motherduck + github-work via proxy), skills pre-installed at build time. Needed fnm + node install in Dockerfile (exeuntu base doesn't ship node — installed at runtime by exe.dev init). Personal dotfiles layer on top.
- Removed `bootstrap-project`, `data-pipelines`, `exe-dev` skills from dotfiles (not providing enough value; SSH guard hook handles the main exe.dev pain point).
- Gated shared skills in `install.sh` to macOS-only (Linux VMs get them from iv-image).
- Created `join-tailnet` and `upgrade-vm` skills (in iv-image repo + dotfiles). These were documented in tailnet.md but never committed as actual skills.
- Upgraded all three VMs (iv-iv, iv-gitlake, iv-gitlake-examples) to iv-image:2.1.0 using upgrade-vm skill. Re-attached repo integrations and re-provisioned doc sites.
- Renamed `kylelundstedt/iv` repo to `kylelundstedt/iv-docs`. Replaced iv-iv VM with iv-docs VM. Updated exe.dev integration (`github-kylelundstedt-iv-docs`), local clone (`~/github/kylelundstedt/iv-docs`), and remote URL.

### 2026-06-11 — earlier

- **Removed baked Tailscale auto-join — switched to on-demand (iv-image 2.0).** Deleted `ts-bootstrap`/`iv-tailscale-join`/service from iv-image; image now ships `tailscaled` enabled but idle. Cleared the exe.dev `new.setup-script` account default (was `/usr/local/bin/ts-bootstrap`, which silently broke plain exeuntu VMs). Deleted `exe-setup.sh`.
- New `join-tailnet` skill — SSHes into a VM over `*.exe.xyz` and runs `tailscale up` with a one-use key minted via the `tailscale-api` proxy; starts `tailscaled` if not running (works on stock exeuntu too).
- New `upgrade-vm` skill — reprovisions a VM onto a newer image without a `-1` tailnet name: deletes the stale node and tears down the stale SSH master + known_hosts entry before recreating. Migrated `iv-iv`, `iv-gitlake`, `iv-gitlake-examples` to `iv-image:2`.
- `test-install.sh` hook check inverted: now asserts **no** `new.setup-script` hook is registered (auto-join must not silently return).
- Obsoletes the exe.dev metadata-proxy boot delay: on-demand join doesn't run at boot, so the ~90–110s `169.254.169.254` routing delay no longer gates tailnet access.

## 2026-06-10

- Switched to iv-image 1.7 + `ts-bootstrap` as the setup script (deleted `exe-setup.sh`). Fixed stale node race (1.6) and POST retry (1.7).
- Rewrote exe-dev skill setup section for the three-layer model (iv-image → dotfiles → repo clone)
- SSH guard hook in `~/.claude/settings.json` — blocks concurrent SSH to exe.dev hosts

## 2026-05-30

- SSH config: single-source-of-truth rewrite — install.sh generates `~/.ssh/config` from scratch, removed ssh stow package
- Duplicated `exe-setup.sh`'s Tailscale proxy / auth-key / ghost-node logic into install.sh's `setup_tailscale` so install.sh works standalone. (`exe-setup.sh` itself remains in the repo — it's the URL artifact exe.dev's default-setup-script hook fetches at first boot. The 93e4076 deletion of the file was a regression; restored same day along with a smoke test in test-install.sh.)
- Fixed `User exedev` scope — was `*.exe.xyz *.ts.net` (applied to all tailnet hosts incl. Macs), now `*.exe.xyz` only
- Pre-seed exe.dev host key in known_hosts (wildcard `*.exe.xyz` entry, no more `StrictHostKeyChecking=accept-new`)
- `TS_HOSTNAME` defaults to `$(hostname)` so Tailscale name always matches VM name
- Dynamic SSH routing for tag:dev tailnet peers — `Match host *.ts.net exec` block + `~/.local/bin/ssh-tailnet-tagged` helper. `ssh <vm>` now Just Works for any current/future exe.dev VM without re-running install.sh per host. Host-key checking disabled for matched hosts (WireGuard is the trust anchor).
- test-install.sh: `test_hook_url` + `test_hook_registration` smoke checks. The second one catches drift between `exe-setup.sh` (fast, Tailscale-first ~6s) and `install.sh` (slow, Tailscale-last ~34s) being registered as the hook — both are functional, so the failure mode is silent slowness, not breakage.
- Re-registered exe.dev hook to `exe-setup.sh`. Had drifted to `install.sh` (likely during 93e4076's "fold exe-setup.sh into install.sh"). VMs were bootstrapping but taking ~34s to tailnet instead of ~6s. Measured 5.84s peer-visible after fix.

## 2026-05-23

- install.sh: skip redundant downloads on exeuntu (`need` guards, skip apt-get when packages present)
- install.sh: skip Codex MCP add on non-interactive sessions (was hanging on headless VMs)
- install.sh: `User root` → `User exedev` in SSH config (Tailscale SSH hangs as root on exeuntu)
- install.sh: GitHub MCP servers via exe.dev HTTP proxy on VMs (`github-mcp-home`, `github-mcp-work`)
- install.sh: MotherDuck MCP via exe.dev HTTP proxy on VMs (`motherduck-mcp`)
- exe.dev default setup script (`exe-setup.sh`): Tailscale via API proxy, ghost node cleanup, dotfiles
- `tailscale-api` HTTP proxy integration on exe.dev — no secrets on VM
- exe-dev skill updated with MCP proxy setup and bootstrap flow
- agent_docs: rewrote secrets.md and linux.md for exe.dev era
- sync-repos.sh: fast-forward default branch after fetch; split work repos by org; added USAA org
- Restructured `~/github/` from flat `klundstedt/` to per-org directories (IndustryVault, iv-cmg, USAA)

## 2026-05-20

- Zed: removed `agent_servers` ACP block (Anthropic billing change)
- Zed: `skip-worktree` for `ssh_connections` — no more git churn
- install.sh: `gh` CLI auth via OAuth (macOS) or PAT (Linux)
- install.sh: native Codex binary (brew cask on macOS, GitHub release on Linux)
- install.sh: OAuth MCP servers for Codex (motherduck, tigris, readwise)
- Recovered missing `github-home` MCP on klundstedt-mini
- `zsh/.profile`: documented `GITHUB_TOKEN` export rationale

## 2026-05-01

- **exe.dev consolidation.** Decision: exe.dev is the primary dev-VM platform; Apple Containers and Sprites on back burner. Demoted `apple-containers`/`sprites-dev` in `CLAUDE.md`/`AGENTS.md` to "alternative, not actively maintained"; marked `test-install.sh`'s Apple Container and Sprite paths informational.

## 2026-04-20

- Snowflake CLI (`snow`) via `uv tool install`

## 2026-04-12

- Unified SSH agent forwarding across all three VM platforms
- Login-time commit signing hook in .zshrc
- SSH hostname canonicalization for MagicDNS
- Kernel-mode tailscaled on exe.dev

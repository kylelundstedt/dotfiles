# TODO

## Zed remote folder in existing window (CLI)

- [ ] Track [zed-industries/zed#56282](https://github.com/zed-industries/zed/issues/56282) — `zed ssh://` always opens a new window; `--add` and `--existing` flags don't work with SSH URLs. Workaround: "projects: open remote" in command palette.

## Secrets on remote VMs

Strategy: no plaintext secrets on VM disk. Each secret uses the narrowest delivery mechanism available.

| Secret                       | Mechanism                                                             | Status            |
| ---------------------------- | --------------------------------------------------------------------- | ----------------- |
| GitHub clone/push            | exe.dev GitHub integration                                            | Done              |
| Tailscale auth key           | exe.dev HTTP proxy integration → ephemeral key per boot               | Done (2026-05-23) |
| Tailscale ghost node cleanup | Setup script via same HTTP proxy                                      | Done (2026-05-23) |
| Git commit signing           | SSH agent forwarding via Tailscale                                    | Done              |
| MCP MotherDuck               | exe.dev HTTP proxy integration (`motherduck-mcp`)                     | Done (2026-05-23) |
| MCP OAuth (Tigris, Readwise) | `LocalForward 8765` on `*.exe.xyz`; browser dance                     | Done (2026-05-17) |
| GitHub MCP PATs on VMs       | exe.dev HTTP proxy integration (`github-mcp-home`, `github-mcp-work`) | Done (2026-05-23) |
| Per-project app secrets      | 1P service account + `op run --env-file`                              | Not started       |

### To do

- [ ] Create per-project 1P service account (read-only access to project vault)
- [ ] Extend `install.sh` to accept `OP_SERVICE_ACCOUNT_TOKEN` env var; write to `~/.config/op/sa-token`
- [ ] Validate `op run --env-file` flow on a real project
- [ ] Rotate Tailscale API key before 2026-08-21 (`ssh exe.dev integrations remove tailscale-api` then re-add)
- [ ] Rotate GitHub PATs when expired (`ssh exe.dev integrations remove github-mcp-home` then re-add)

## exe.dev consolidation

Decision (2026-05-01): exe.dev is the primary dev-VM platform. Apple Containers and Sprites are on back burner.

- [ ] Demote `apple-containers` and `sprites-dev` in `CLAUDE.md` and `AGENTS.md` to "alternative, not actively maintained"
- [ ] Mark `test-install.sh`'s Apple Container and Sprite paths informational

## Tailscale ACL

- [ ] Tighten `tag:dev` → `tag:dev` SSH users list (currently allows `root` + `autogroup:nonroot`; consider restricting to `exedev` only)
- [ ] Consider port-restricting the network grant (`*:22` instead of `"ip": ["*"]`)

## exe.dev multi-tenant (future)

Decision (2026-05-23): single tailnet for now (Option 1 — you create VMs, contractors use them via `*.exe.xyz`). Move to per-tenant tailnets (Option 2) when there's a paying client.

- [ ] Per-tenant Tailscale tailnet + API key + `tailscale-api-<client>` integration scoped to `tag:<client>`
- [ ] Per-tenant setup script (parameterize install.sh's `setup_tailscale`)
- [ ] Team integrations (`--team`) for client-scoped MCP servers

## agent-shell (evaluation)

Tigris-backed virtual shell for agent workspaces — atomic writes, fork/snapshot, multi-mount. See `agent_docs/agent-shell-eval.md`.

- [ ] Smoke-test: install, write/read/flush against existing Tigris bucket
- [ ] Test fork semantics: fork, write to fork, verify source unchanged, delete fork
- [ ] Test atomic failure: write files, throw before flush, confirm bucket clean
- [ ] Integration test on exe.dev VM (auth via integration proxy or forwarded creds)
- [ ] Prototype: IV digest using llm-digest pattern (cron → agent → flush → presign → Slack)

## Basic Memory (evaluation)

Cross-AI / multi-machine persistent memory via Basic Memory (basicmachines-co). Claude Code's built-in auto-memory is per-machine, not synced, and Claude-only; Codex has its own native memory.

- [ ] Pick hosting model: local vs Cloud vs Teams
- [ ] Trial on one project, evaluate over 1–2 weeks
- [ ] If kept: install on all machines, document policy distinguishing Basic Memory vs Claude auto-memory vs Codex native memory

## install.sh hygiene

- [ ] Replace swallowed errors in `setup_agents` (`>/dev/null 2>&1 || true` → explicit `echo "[!] X failed"` on non-zero)

## Done (2026-06-11)

- [x] **Baked team agent config into iv-image.** New `agent/` directory: team AGENTS.md, Claude Code settings.json (SSH guard hook), MCP pre-registration (motherduck + github-work via proxy), skills pre-installed at build time. Personal dotfiles layer on top.
- [x] Removed `bootstrap-project`, `data-pipelines`, `exe-dev` skills from dotfiles (not providing enough value; SSH guard hook handles the main exe.dev pain point).
- [x] Gated shared skills in `install.sh` to macOS-only (Linux VMs get them from iv-image).

## Done (2026-06-11) — earlier

- [x] **Removed baked Tailscale auto-join — switched to on-demand (iv-image 2.0).** Deleted `ts-bootstrap`/`iv-tailscale-join`/service from iv-image; image now ships `tailscaled` enabled but idle. Cleared the exe.dev `new.setup-script` account default (was `/usr/local/bin/ts-bootstrap`, which silently broke plain exeuntu VMs). Deleted `exe-setup.sh`.
- [x] New `join-tailnet` skill — SSHes into a VM over `*.exe.xyz` and runs `tailscale up` with a one-use key minted via the `tailscale-api` proxy; starts `tailscaled` if not running (works on stock exeuntu too).
- [x] New `upgrade-vm` skill — reprovisions a VM onto a newer image without a `-1` tailnet name: deletes the stale node and tears down the stale SSH master + known_hosts entry before recreating. Migrated `iv-iv`, `iv-gitlake`, `iv-gitlake-examples` to `iv-image:2`.
- [x] `test-install.sh` hook check inverted: now asserts **no** `new.setup-script` hook is registered (auto-join must not silently return).
- Obsoletes the exe.dev metadata-proxy boot delay: on-demand join doesn't run at boot, so the ~90–110s `169.254.169.254` routing delay no longer gates tailnet access.

## Done (2026-06-10)

- [x] Switched to iv-image 1.7 + `ts-bootstrap` as the setup script (deleted `exe-setup.sh`). Fixed stale node race (1.6) and POST retry (1.7).
- [x] Rewrote exe-dev skill setup section for the three-layer model (iv-image → dotfiles → repo clone)
- [x] SSH guard hook in `~/.claude/settings.json` — blocks concurrent SSH to exe.dev hosts

## Done (2026-05-30)

- [x] SSH config: single-source-of-truth rewrite — install.sh generates `~/.ssh/config` from scratch, removed ssh stow package
- [x] Duplicated `exe-setup.sh`'s Tailscale proxy / auth-key / ghost-node logic into install.sh's `setup_tailscale` so install.sh works standalone. (`exe-setup.sh` itself remains in the repo — it's the URL artifact exe.dev's default-setup-script hook fetches at first boot. The 93e4076 deletion of the file was a regression; restored same day along with a smoke test in test-install.sh.)
- [x] Fixed `User exedev` scope — was `*.exe.xyz *.ts.net` (applied to all tailnet hosts incl. Macs), now `*.exe.xyz` only
- [x] Pre-seed exe.dev host key in known_hosts (wildcard `*.exe.xyz` entry, no more `StrictHostKeyChecking=accept-new`)
- [x] `TS_HOSTNAME` defaults to `$(hostname)` so Tailscale name always matches VM name
- [x] Dynamic SSH routing for tag:dev tailnet peers — `Match host *.ts.net exec` block + `~/.local/bin/ssh-tailnet-tagged` helper. `ssh <vm>` now Just Works for any current/future exe.dev VM without re-running install.sh per host. Host-key checking disabled for matched hosts (WireGuard is the trust anchor).
- [x] test-install.sh: `test_hook_url` + `test_hook_registration` smoke checks. The second one catches drift between `exe-setup.sh` (fast, Tailscale-first ~6s) and `install.sh` (slow, Tailscale-last ~34s) being registered as the hook — both are functional, so the failure mode is silent slowness, not breakage.
- [x] Re-registered exe.dev hook to `exe-setup.sh`. Had drifted to `install.sh` (likely during 93e4076's "fold exe-setup.sh into install.sh"). VMs were bootstrapping but taking ~34s to tailnet instead of ~6s. Measured 5.84s peer-visible after fix.

## Done (2026-05-23)

- [x] install.sh: skip redundant downloads on exeuntu (`need` guards, skip apt-get when packages present)
- [x] install.sh: skip Codex MCP add on non-interactive sessions (was hanging on headless VMs)
- [x] install.sh: `User root` → `User exedev` in SSH config (Tailscale SSH hangs as root on exeuntu)
- [x] install.sh: GitHub MCP servers via exe.dev HTTP proxy on VMs (`github-mcp-home`, `github-mcp-work`)
- [x] install.sh: MotherDuck MCP via exe.dev HTTP proxy on VMs (`motherduck-mcp`)
- [x] exe.dev default setup script (`exe-setup.sh`): Tailscale via API proxy, ghost node cleanup, dotfiles
- [x] `tailscale-api` HTTP proxy integration on exe.dev — no secrets on VM
- [x] exe-dev skill updated with MCP proxy setup and bootstrap flow
- [x] agent_docs: rewrote secrets.md and linux.md for exe.dev era
- [x] sync-repos.sh: fast-forward default branch after fetch; split work repos by org; added USAA org
- [x] Restructured `~/github/` from flat `klundstedt/` to per-org directories (IndustryVault, iv-cmg, USAA)

## Done (2026-05-20)

- [x] Zed: removed `agent_servers` ACP block (Anthropic billing change)
- [x] Zed: `skip-worktree` for `ssh_connections` — no more git churn
- [x] install.sh: `gh` CLI auth via OAuth (macOS) or PAT (Linux)
- [x] install.sh: native Codex binary (brew cask on macOS, GitHub release on Linux)
- [x] install.sh: OAuth MCP servers for Codex (motherduck, tigris, readwise)
- [x] Recovered missing `github-home` MCP on klundstedt-mini
- [x] `zsh/.profile`: documented `GITHUB_TOKEN` export rationale

## Done (2026-04-20)

- [x] Snowflake CLI (`snow`) via `uv tool install`

## Done (2026-04-12)

- [x] Unified SSH agent forwarding across all three VM platforms
- [x] Login-time commit signing hook in .zshrc
- [x] SSH hostname canonicalization for MagicDNS
- [x] Kernel-mode tailscaled on exe.dev

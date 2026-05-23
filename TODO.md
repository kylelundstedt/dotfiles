# TODO

## Zed remote folder in existing window (CLI)

- [ ] Track [zed-industries/zed#56282](https://github.com/zed-industries/zed/issues/56282) — `zed ssh://` always opens a new window; `--add` and `--existing` flags don't work with SSH URLs. Workaround: "projects: open remote" in command palette.

## Secrets on remote VMs

Strategy: no plaintext secrets on VM disk. Each secret uses the narrowest delivery mechanism available.

| Secret                                   | Mechanism                                                  | Status            |
| ---------------------------------------- | ---------------------------------------------------------- | ----------------- |
| GitHub clone/push                        | exe.dev GitHub integration                                 | Done              |
| Tailscale auth key                       | exe.dev HTTP proxy integration → ephemeral key per boot    | Done (2026-05-23) |
| Tailscale ghost node cleanup             | Setup script via same HTTP proxy                           | Done (2026-05-23) |
| Git commit signing                       | SSH agent forwarding via Tailscale                         | Done              |
| MCP MotherDuck                           | exe.dev HTTP proxy integration (`motherduck-mcp`)          | Done (2026-05-23) |
| MCP OAuth (Tigris, Readwise)             | `LocalForward 8765` on `*.exe.xyz`; browser dance          | Done (2026-05-17) |
| GitHub MCP PATs on VMs                   | exe.dev HTTP proxy integration (`github-mcp-home`, `github-mcp-work`) | Done (2026-05-23) |
| Per-project app secrets                  | 1P service account + `op run --env-file`                   | Not started       |

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

## Basic Memory (evaluation)

Cross-AI / multi-machine persistent memory via Basic Memory (basicmachines-co). Claude Code's built-in auto-memory is per-machine, not synced, and Claude-only; Codex has its own native memory.

- [ ] Pick hosting model: local vs Cloud vs Teams
- [ ] Trial on one project, evaluate over 1–2 weeks
- [ ] If kept: install on all machines, document policy distinguishing Basic Memory vs Claude auto-memory vs Codex native memory

## install.sh hygiene

- [ ] Replace swallowed errors in `setup_agents` (`>/dev/null 2>&1 || true` → explicit `echo "[!] X failed"` on non-zero)

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

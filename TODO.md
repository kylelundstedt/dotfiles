# TODO

## Zed remote folder in existing window (CLI)

- [ ] Verify on installed Zed: [zed-industries/zed#56282](https://github.com/zed-industries/zed/issues/56282) closed COMPLETED upstream 2026-06-26 — `--add`/`--existing` with SSH URLs should now work. Confirm the build in use has the fix; if so, drop the "projects: open remote" palette workaround.

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

## Tailscale ACL

- [ ] Tighten `tag:dev` → `tag:dev` SSH users list (currently allows `root` + `autogroup:nonroot`; consider restricting to `exedev` only)
- [ ] Consider port-restricting the network grant (`*:22` instead of `"ip": ["*"]`)

## exe.dev multi-tenant (future)

Decision (2026-05-23): single tailnet for now (Option 1 — you create VMs, contractors use them via `*.exe.xyz`). Move to per-tenant tailnets (Option 2) when there's a paying client.

Decision (2026-05-30): when Option 2 lands, pair per-client tailnet with **per-client exe.dev account** and the "switch-the-Mac" operational pattern (`tailscale switch` between client tailnets). Full doc: `gitlake:iv/reference/exe_dev_multi_tenant.md`. Tag stays as `tag:dev` within each tailnet — isolation is at the account+tailnet boundary, not the tag.

Pre-requisite dotfiles work (in order):

- [ ] Factor `install.sh setup_git`'s SSH-config generation into a standalone `regen-ssh-config` script invoked by `ts-switch`
- [ ] `ts-switch <clientid>` zsh function in `zsh/.zshrc`: `tailscale switch iv-<clientid> && regen-ssh-config`
- [ ] `install.sh setup_tailscale` (macOS): support adding multiple `tailscale up` profiles, one per client tailnet
- [ ] `install.sh setup_git`: emit per-account `Host exe-<clientid>.dev` blocks (with per-account `IdentityFile`) from a `clients.conf` at repo root
- [ ] `test-install.sh test_hook_registration`: iterate over a list of accounts from `clients.conf`
- [ ] `bin/add-client <clientid>` helper: one-shot create of tailnet API key + `tailscale-api` integration + hook registration + 1Password entries + `clients.conf` row
- [ ] `exe-setup.sh`: honor `TS_HOSTNAME` env-var override (today always uses `$(hostname)`; install.sh already does override) — keeps Tailscale name distinct from exe.dev OS hostname when desired
- [ ] Earlier items (still relevant): per-tenant Tailscale tailnet + API key + `tailscale-api-<client>` integration, team integrations (`--team`) for client-scoped MCP servers

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

---

Completed work has moved to [CHANGELOG.md](CHANGELOG.md).

# TODO

## personal-mcp / archives hub (klundstedt-mini)

The `hub-mcp` unified-search server and its ingest pipeline now live in the private
`kylelundstedt/personal-mcp` repo (split 2026-07-10); serving-side TODOs move there.
What stays here is the MCP _client_ registration (`install.sh`).

- [ ] **Connect MCP clients on other devices** — `install.sh` now auto-registers `hub-mcp` on personal Macs (#14: localhost on the mini, tailnet URL elsewhere if reachable), so a fresh `klundstedt-mbp` install picks it up. `klundstedt-iphone` needs the Tailscale app reconnected first (offline ~231d as of 2026-06), then point its MCP client at `https://klundstedt-mini.dojo-sun.ts.net/mcp`.

## Secrets on remote VMs

Strategy: no plaintext secrets on VM disk. Each secret uses the narrowest delivery mechanism available.

| Secret                       | Mechanism                                                             | Status            |
| ---------------------------- | --------------------------------------------------------------------- | ----------------- |
| GitHub clone/push            | exe.dev GitHub integration                                            | Done              |
| Tailscale auth key           | OAuth client behind exe.dev proxy → 1h token → ephemeral key per join | Done (2026-07-13) |
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
- [ ] `test-install.sh test_no_hook`: iterate over a list of accounts from `clients.conf`
- [ ] `bin/add-client <clientid>` helper: one-shot create of tailnet API key + `tailscale-api` integration + hook registration + 1Password entries + `clients.conf` row
- [ ] Earlier items (still relevant): per-tenant Tailscale tailnet + API key + `tailscale-api-<client>` integration, team integrations (`--team`) for client-scoped MCP servers

## Basic Memory (evaluation)

Cross-AI / multi-machine persistent memory via Basic Memory (basicmachines-co). Claude Code's built-in auto-memory is per-machine, not synced, and Claude-only; Codex has its own native memory.

- [ ] Pick hosting model: local vs Cloud vs Teams
- [ ] Trial on one project, evaluate over 1–2 weeks
- [ ] If kept: install on all machines, document policy distinguishing Basic Memory vs Claude auto-memory vs Codex native memory

## install.sh / script hygiene (from the 2026-07-13 repo review)

- [ ] Replace swallowed errors in `setup_agents` (`>/dev/null 2>&1 || true` → explicit `echo "[!] X failed"` on non-zero)
- [ ] Split `setup_agents` (~350 lines, six concerns) and `setup_git` (git config + two SSH strategies) into focused functions
- [ ] Adopt `backup/_lib.sh` in `owc8tb-unlock.sh`, `check-key-expiry.sh`, `check-monitoring.sh` (hand-rolled `job_kc`/`job_hc`/mini-guard copies); unify the three manifest-field trim idioms
- [ ] `settings.json` propagation: install.sh seeds from the example only when absent, so new hooks never reach existing installs — add an idempotent merge (like `overlay_claude_settings`)
- [ ] Reconcile or retire `upgrade-vm.sh` (automates the pre-stock-exeuntu registry flow; SKILL.md now documents reprovision-in-place as the default)
- [ ] Align `test-install.sh`'s VERIFY_SCRIPT tool list with `provisioning/tools.manifest` (or annotate it as a deliberate smoke subset)

---

Completed work has moved to [CHANGELOG.md](CHANGELOG.md).

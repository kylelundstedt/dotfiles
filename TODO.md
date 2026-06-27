# TODO

## Zed remote folder in existing window (CLI)

- [ ] Verify on installed Zed: [zed-industries/zed#56282](https://github.com/zed-industries/zed/issues/56282) closed COMPLETED upstream 2026-06-26 — `--add`/`--existing` with SSH URLs should now work. Confirm the build in use has the fix; if so, drop the "projects: open remote" palette workaround.

## personal-mcp / archives hub (klundstedt-mini)

The `hub-mcp` unified-search server and its ingest pipeline. Canonical, fuller TODO
lives in `~/archives/README.md` on klundstedt-mini (not in git); these are the items
worth tracking where the code lives. See [agent_docs/personal-mcp.md](agent_docs/personal-mcp.md).

- [ ] **Test MCP access from other devices** — connect `klundstedt-mbp` (online) and `klundstedt-iphone` (was offline ~231d, needs Tailscale reconnected) to `https://klundstedt-mini.dojo-sun.ts.net/mcp`.
- [ ] **Extend semantic search beyond web** — embed calendar event summaries (~42k, cheap) and wire in email semantic by reusing msgvault's `vectors.db` (nomic-768/sqlite-vec; all sources nomic-768/cosine so scores merge cleanly).
- [ ] **Message-text freshness** — msgvault's `apple_messages` sync lags, so hub `imessage`/`sms` text is only current to its last sync (attachment items are current to the last iPhone backup). Either schedule the Apple Messages sync or source text from the backup's `sms.db`. Note: `messages/messages.duckdb` has no scheduled rebuild (`build_index.py` is manual).
- [ ] **Stagger backup vs web-archive refresh** — `web-archive-refresh.sh` and `tigris-backup.sh` both fire at 04:00. The backup's `pgrep` guard only checks for a running `rclone`, not the refresh job, so the backup can copy `web-archive.duckdb` / the hub rebuild mid-write. Move the backup to 05:00 or coordinate via lock. (Low impact — both are regenerable from `sources/`.)
- [ ] **Date-parse artifacts** (cosmetic) — junk rows in bad partitions: email `year=2`/`year=1601`, calendar min `start_date` 1604 (Windows FILETIME epoch). Add a parse-fallback / drop unparseable timestamps in the build scripts.
- [ ] **Remove Web Clipper browser extension** — vault `Clippings/` is gone; confirm the extension is uninstalled so it stops offering to clip. (Likely already done in the 2026-06-27 session — verify.)

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

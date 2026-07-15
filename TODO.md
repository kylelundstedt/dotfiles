# TODO

Open work only, grouped by when it can happen. Completed work →
[CHANGELOG.md](CHANGELOG.md). Runbooks, status tables, decisions, and plans →
[agent_docs/](agent_docs/README.md).

## Actionable now

- [ ] Run `./install.sh` on klundstedt-mbp (no full run since the simplification plan)
- [ ] Split `setup_agents` and `setup_git` into focused functions; verify with `./test-install.sh overlay` + `exe`
- [ ] Tailscale admin console: tighten `tag:dev` SSH users (drop `root`/`autogroup:nonroot` → `exedev`); consider `*:22` instead of `"ip": ["*"]` in the network grant

## Waiting on a trigger

- [ ] Point the iPhone MCP client at `https://klundstedt-mini.dojo-sun.ts.net/mcp` — blocked on reconnecting its Tailscale app (offline since ~2025-11)
- [ ] Per-project app secrets on VMs: 1P service account + `op run --env-file` (SA creation, `OP_SERVICE_ACCOUNT_TOKEN` support in install.sh, validate on a real project) — when the first project needs one
- [ ] provision-iv.sh (iv-image): merge `~/.claude/settings.json` instead of overwriting — only if the upgrade-vm skill's re-run-the-overlay step proves error-prone in practice
- [ ] exe.dev multi-tenant build-out — gated on first paying client; decisions + ordered checklist in [agent_docs/multi-tenant.md](agent_docs/multi-tenant.md)

## Evaluations (no deadline)

- [ ] Basic Memory: pick hosting model (local/Cloud/Teams), trial 1–2 weeks on one project, then adopt-or-drop with a policy note distinguishing it from Claude/Codex native memory

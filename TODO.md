# TODO

Open work only, grouped by when it can happen. Completed work →
[CHANGELOG.md](CHANGELOG.md). Runbooks, status tables, decisions, and plans →
[agent_docs/](agent_docs/README.md).

## Actionable now

- [ ] herdr + Moshi pilot — **phone path proven 2026-07-18** (Moshi iPhone → mini via `sshd:2222` → herdr; `herdr-layout` helper deployed fleet-wide). Remaining: detach/reattach + `--takeover` semantics check, one week of real use, then retire Shelley carve-outs. Plugin options surfaced (collie phone web-PWA, herdr-reviewr, moshi-hook notifications) — see [agent_docs/herdr-pilot.md](agent_docs/herdr-pilot.md)
- [ ] Split `setup_agents` and `setup_git` into focused functions; verify with `./test-install.sh overlay` + `exe`
- [ ] Tailscale admin console: tighten `tag:dev` SSH users (drop `root`/`autogroup:nonroot` → `exedev`); consider `*:22` instead of `"ip": ["*"]` in the network grant
- [ ] Request `github-ro` from exe.dev (Discord https://discord.gg/jc9WQUfaxf), then `integrations edit github-kylelundstedt-{dotfiles,iv-image} --readonly` — least privilege on VMs (they consume, not develop, those repos); details in [agent_docs/git-identity.md](agent_docs/git-identity.md)

## Waiting on a trigger

- [ ] Mobile access to hub-mcp: pointing a phone MCP client at the tailnet URL **cannot work** — claude.ai/mobile connectors originate from the vendor's cloud, not the device (see personal-mcp README "iPhone / iPad"). Real options: SSH-to-mini pattern (covered by the herdr pilot) now; OAuth on the server + Tailscale Funnel later (tracked in personal-mcp TODO.md). Reconnect the iPhone's Tailscale app regardless (offline since ~2025-11)
- [ ] Per-project app secrets on VMs: 1P service account + `op run --env-file` (SA creation, `OP_SERVICE_ACCOUNT_TOKEN` support in install.sh, validate on a real project) — when the first project needs one
- [ ] provision-iv.sh (iv-image): merge `~/.claude/settings.json` instead of overwriting — only if the upgrade-vm skill's re-run-the-overlay step proves error-prone in practice
- [ ] exe.dev multi-tenant build-out — gated on first paying client; decisions + ordered checklist in [agent_docs/multi-tenant.md](agent_docs/multi-tenant.md)

## Evaluations (no deadline)

- [ ] Basic Memory: pick hosting model (local/Cloud/Teams), trial 1–2 weeks on one project, then adopt-or-drop with a policy note distinguishing it from Claude/Codex native memory

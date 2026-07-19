# TODO

Open work only, grouped by when it can happen. Completed work →
[CHANGELOG.md](CHANGELOG.md). Runbooks, status tables, decisions, and plans →
[agent_docs/](agent_docs/README.md).

## Actionable now

- [ ] **Migrate LLM gateway onto an AC appliance VM** — currently host-level on klundstedt-mini (LaunchAgents + brew Caddy + vmnet bridge + `:8443` serve). Target: an `llm-gateway` Apple Container appliance VM (exeuntu, `--home-mount none`) in **its own GitHub repo** (personal, like personal-mcp — not baked into `iv-image`), joined to the tailnet doing its own `tailscale serve`, subscription tokens held inside the VM. Rationale + steps in [agent_docs/llm-gateway.md](agent_docs/llm-gateway.md) ("Target architecture"); build/use pattern in [agent_docs/apple-container-vms.md](agent_docs/apple-container-vms.md)
- [ ] iv-sandbox reboot resilience — manual gates then acceptance test: enable **auto-login** (System Settings → Users & Groups) and make the **container-helper App Data Protection grants persist** (Full Disk Access), then run the double-`sudo reboot` + phone-load-`https://iv-sandbox.dojo-sun.ts.net` test with no touch of the mini
- [ ] Update the `apple-containers` skill to the machine-mode approach — it predates this work and still uses `container run` + `ubuntu`; align it with [agent_docs/apple-container-vms.md](agent_docs/apple-container-vms.md)
- [ ] LLM gateway polish (optional): add CLIProxyAPI `oauth-model-alias` entries so Shelley's `gpt-5.3-codex`/`gpt-5.2-codex`/`gpt-5.4-nano` entries route to served names instead of erroring; provision one scoped repo cred (fine-grained PAT / deploy key) if a private repo is ever needed inside iv-sandbox
- [ ] herdr + Moshi pilot — **phone path proven 2026-07-18** (Moshi iPhone → mini via `sshd:2222` → herdr; `herdr-layout` helper deployed fleet-wide). Remaining: detach/reattach + `--takeover` semantics check, one week of real use, then retire Shelley carve-outs. Plugin options surfaced (collie phone web-PWA, herdr-reviewr, moshi-hook notifications) — see [agent_docs/herdr-pilot.md](agent_docs/herdr-pilot.md)
- [ ] Split `setup_agents` and `setup_git` into focused functions; verify with `./test-install.sh overlay` + `exe`
- [ ] Tailscale admin console: tighten `tag:dev` SSH users (drop `root`/`autogroup:nonroot` → `exedev`); consider `*:22` instead of `"ip": ["*"]` in the network grant
- [ ] Request `github-ro` from exe.dev (Discord https://discord.gg/jc9WQUfaxf), then `integrations edit github-kylelundstedt-{dotfiles,iv-image} --readonly` — least privilege on VMs (they consume, not develop, those repos); details in [agent_docs/git-identity.md](agent_docs/git-identity.md)

## Waiting on a trigger

- [ ] Decide whether to retire `iv-home` — explicitly deferred 2026-07-19. It currently serves the closed-door corporate repo read-only on the tailnet only; do not change or delete it until this decision is revisited.

- [ ] Mobile access to hub-mcp: pointing a phone MCP client at the tailnet URL **cannot work** — claude.ai/mobile connectors originate from the vendor's cloud, not the device (see personal-mcp README "iPhone / iPad"). Real options: SSH-to-mini pattern (covered by the herdr pilot) now; OAuth on the server + Tailscale Funnel later (tracked in personal-mcp TODO.md). Reconnect the iPhone's Tailscale app regardless (offline since ~2025-11)
- [ ] Per-project app secrets on VMs: 1P service account + `op run --env-file` (SA creation, `OP_SERVICE_ACCOUNT_TOKEN` support in install.sh, validate on a real project) — when the first project needs one
- [ ] provision-iv.sh (iv-image): merge `~/.claude/settings.json` instead of overwriting — only if the upgrade-vm skill's re-run-the-overlay step proves error-prone in practice
- [ ] exe.dev multi-tenant build-out — gated on first paying client; decisions + ordered checklist in [agent_docs/multi-tenant.md](agent_docs/multi-tenant.md)

## Evaluations (no deadline)

- [ ] Basic Memory: pick hosting model (local/Cloud/Teams), trial 1–2 weeks on one project, then adopt-or-drop with a policy note distinguishing it from Claude/Codex native memory

# agent_docs

Durable reference context for AI agents (and humans) working in this repo — the
knowledge that isn't derivable from the code or git history: env/tooling
gotchas, platform findings, runbooks, decision rationale, forward plans, and
handoff notes. One topic per file, indexed below.

Only committed content is durable: it survives machine/VM rebuilds and is
visible to every harness (Claude, Codex, Shelley), unlike a harness's native
memory store. Three stores, cleanly split:

- **Open work** → [`TODO.md`](../TODO.md)
- **Completed work** → [`CHANGELOG.md`](../CHANGELOG.md)
- **Durable reference** → here

On-demand workflows live in skills (`agents/.agents/skills/`), not here;
always-on rules live in `AGENTS.md`.

| File                         | Purpose                                                                                     |
| ---------------------------- | ------------------------------------------------------------------------------------------- |
| `hosts.md`                   | Where this runs — the two Macs (mini vs mbp) and the Linux VM fleet + testing               |
| `exe-dev.md`                 | exe.dev fleet specifics — SSH rate-limit discipline, no-hook contract, reflection           |
| `exe-dev-web.md`             | exe.dev app/Shelley endpoint model + 2026-07-19 fleet web audit                             |
| `git-identity.md`            | Repo layout + commit identity across macOS & exe.dev VMs (hasconfig-by-org)                 |
| `git-https-migration.md`     | HTTPS-only Git transport migration, canary, fleet rollout, and rollback                     |
| `agents-recommendations.md`  | Operating patterns, dual-agent workflows, task routing, maintenance checklists              |
| `model-routing-economics.md` | Subscription strategy, model routing, and Shelley cost-evaluation method                    |
| `repo-boundaries.md`         | Decision: what belongs in dotfiles, split criteria, multi-tenant trigger                    |
| `tigris-backup-runbook.md`   | klundstedt-mini → Tigris encrypted backup runbook                                           |
| `apple-container-vms.md`     | Creating & using Apple Container VMs (exe.dev-equivalent, machine mode + Shelley)           |
| `llm-gateway.md`             | Self-hosted Claude/Codex subscription LLM gateway on the mini — current form + target VM    |
| `llm-gateway-migration.md`   | Approved plan: gateway host stack → AC appliance VM — phases, gates, host-fragility posture |
| `service-placement.md`       | Criterion: AC appliance VM vs. host for mini services (llm-gateway yes, personal-mcp no)    |
| `monitoring.md`              | healthchecks.io registry — job↔check schedule pairs, grace rules, incidents                 |
| `secrets.md`                 | Secret management — exe.dev integrations, 1Password patterns, MCP server auth               |
| `multi-tenant.md`            | Future multi-tenant plan (gated on first paying client) — decisions, checklist              |
| `herdr-pilot.md`             | herdr + Moshi agent-workflow pilot — topology decisions, boundaries, checklist              |
| `agentsview-pilot.md`        | Approved fleet pilot — central Shelley/Claude/Codex history across exe.dev and AC VMs       |
| `shelley-sovreignty.md`      | Shelley assessment + target architecture for sovereign operating memory                     |

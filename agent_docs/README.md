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

| File                        | Purpose                                                                        |
| --------------------------- | ------------------------------------------------------------------------------ |
| `machines.md`               | The two Macs (mini vs mbp) — roles, Tailscale posture, what runs where         |
| `agents-recommendations.md` | Operating patterns, dual-agent workflows, task routing, maintenance checklists |
| `repo-boundaries.md`        | Decision: what belongs in dotfiles, split criteria, multi-tenant trigger       |
| `tigris-backup-runbook.md`  | klundstedt-mini → Tigris encrypted backup runbook                              |
| `monitoring.md`             | healthchecks.io registry — job↔check schedule pairs, grace rules, incidents    |
| `linux.md`                  | Linux platform notes and testing                                               |
| `secrets.md`                | Secret management — exe.dev integrations, 1Password patterns, MCP server auth  |
| `multi-tenant.md`           | Future multi-tenant plan (gated on first paying client) — decisions, checklist |
| `herdr-pilot.md`            | herdr + Moshi agent-workflow pilot — topology decisions, boundaries, checklist |

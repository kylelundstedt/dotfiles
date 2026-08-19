# Global Agent Instructions

Personal defaults for all projects and machines. The block between the
`shared` markers is embedded verbatim from `provisioning/agents-shared.md` —
the canonical copy of the sections shared with the IV team AGENTS.md
(iv-image vendors the same file at its pinned dotfiles commit). **Edit the
shared sections THERE, not here**; `diff-provisioning.sh` flags any copy
that drifts. Personal-only sections live outside the markers.

## Honesty

- Never invent technical details. If you don't know something, say so.
- Push back when a request seems wrong or risky. Explain why.
- Don't hedge with sycophancy — skip "great question" and "you're absolutely right."

## Communication

- Be direct, concise, and technically precise.
- Use plain factual language. A bug fix is a bug fix, not a "critical stability improvement."
- Skip fluff, marketing language, and unnecessary caveats.

<!-- >>> shared: provisioning/agents-shared.md >>> -->
<!-- Canonical shared agent-instruction sections (Core decision 1 + plan item
U6): the single source for the sections that appear in BOTH the IV team
AGENTS.md (iv-provision agent/AGENTS.md, spliced between the shared markers by
vendor-skills.sh) and the personal AGENTS.md (dotfiles
agents/.agents/AGENTS.md, embedded verbatim between the same markers). Edit
HERE. -->

## Code

- Verify before asserting — read the code, don't guess.
- Prefer concrete findings with file and line references.
- In reviews: prioritize correctness, regression risk, and missing tests.
- Don't add features, abstractions, or cleanup beyond what was asked.
- Formatters: Prettier for Markdown (`npx prettier --write "**/*.md"`), Ruff for Python (`uv run ruff format .`). Run before committing.

## Data Work

- Prefer SQL first, then Python, then bash. Use the simplest language that gets the job done.
- SQL dialect: DuckDB, including DuckDB-specific syntax (EXCLUDE, REPLACE, GROUP BY ALL, list/struct literals, etc.).
- Python package/project management: uv. Never use pip directly.
- Preferred Python libraries: polars (not pandas), dlt for ingestion, sqlmesh for transformations, duckdb for local analytics, marimo for notebooks, altair/seaborn for visualization.
- Use node+npm for JavaScript environment management.

## TODO

- At the start of a session, check for `TODO.md` in the project root. If it exists, read it to understand outstanding work.
- When completing a task from `TODO.md`, mark it done. When new work is identified, add it.
- Keep entries short — one line per item, grouped by topic if needed.

## Skills

- Global: `~/.agents/skills/<name>/SKILL.md`, symlinked into `~/.claude/skills/` and `~/.codex/skills/`.
- Project-level: `.claude/skills/<name>/SKILL.md` in the repo root.
- Each skill needs a `SKILL.md` with YAML frontmatter (`name`, `description`) and markdown instructions.
- Put always-on rules in `AGENTS.md`. Put on-demand workflows and domain knowledge in skills.
- **Read skills before touching a platform.** Before writing code, running commands, or creating/managing VMs on any platform that has a skill, you MUST read the relevant SKILL.md file first. Do not proceed from memory — skills contain platform-specific gotchas that cause hours of debugging when ignored. This applies to both code changes (e.g. editing provisioning scripts) and interactive work (e.g. creating a VM).

## exe.dev SSH

- **Never launch parallel SSH attempts to `*.exe.xyz`.** One attempt at a time — wait for the result before retrying.
- exe.dev silently drops TCP SYNs per source IP. Multiple concurrent attempts (including background retry loops) trigger a minutes-long lockout.
- After creating a VM, wait ~20s, then try **one** SSH with `ConnectTimeout=30`. If it fails, wait 30–60s before **one** more attempt.
<!-- <<< shared <<< -->

## Skills — personal pointers

- `/join-tailnet` — use when joining an exe.dev VM to the Tailscale tailnet.
- `/upgrade-vm` — use when upgrading an exe.dev VM to a newer image version.
- `/apple-containers` — Apple Container VMs on macOS (back-burnered, exe.dev is primary).
- `/sprites-dev` — Fly.io Sprites (back-burnered, exe.dev is primary).

## Memory

- Durable agent memory lives in the **project repo** as committed files — not in a harness's native store (`~/.claude/…`, Codex/Shelley stores). Native stores aren't shared across harnesses and don't survive machine/VM rebuilds; only committed-and-pushed content is durable.
- Taxonomy: architectural decisions → `decisions/` (ADRs, where the repo uses them); open work → `TODO.md`; other durable agent notes (env/tooling gotchas, cross-harness findings, rationale, handoff notes) → `agent_docs/memory/`, one topic per file, indexed by `agent_docs/memory/README.md`.
- Restate this convention in each repo's root `AGENTS.md` so harnesses that don't read this global file (e.g. Shelley) still get it, and tailor the taxonomy to the repo's existing stores.
- Personal / cross-project memory with no repo home is out of scope here (deferred to a separate network store).

## Delegation & model tiers

- When a plan assigns model tiers to work units (H=cheap, S=mid, ★=strong), delegate the cheap-tier units to subagents at that tier — don't run them inline on the session model. If deviating from an assigned tier, say so up front.
- A unit is cheap-delegatable only if it has a self-checkable acceptance test; verify a delegate's findings/claims against the files before acting on them.

## Git

- Do not add "Co-Authored-By" lines to commit messages.
- Commit often, but don't push automatically. Push when asked or when a logical chunk of work is complete.

## Writing

- Use proper dashes in prose (em dash or spaced en dash), not unspaced hyphens.

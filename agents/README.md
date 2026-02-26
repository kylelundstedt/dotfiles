# agents

Shared infrastructure for running Claude Code (primary) and Codex CLI (backup) with a single set of instructions, skills, and MCP servers. Both agents read the same `AGENTS.md`, use the same skills, and connect to the same MCP servers — so switching between them is seamless.

See `agent_docs/agents-recommendations.md` for dual-agent workflow patterns (draft/review, parallel debugging, task routing).

## What gets deployed

Stow deploys the core agent infrastructure:

```
~/.agents/AGENTS.md                          ← canonical global instructions
~/.claude/CLAUDE.md → ../.agents/AGENTS.md   ← so Claude Code reads the canonical file
~/.codex/AGENTS.md  → ../.agents/AGENTS.md   ← so Codex reads the canonical file
```

MCP servers are registered as remote HTTP endpoints by `install.sh` — no local wrappers needed. OAuth servers (MotherDuck, Tigris) work on all environments. GitHub servers use PATs from 1Password (macOS only).

Skills are deployed by `npx -y skills add -g -y` (the [skills CLI](https://github.com/vercel-labs/skills)), which installs them directly into `~/.claude/skills/` and `~/.codex/skills/`. The `.stow-local-ignore` file excludes skills from the stow package.

```
~/.agents/skills/bootstrap-project/          ← scaffolds per-project agent context
~/.agents/skills/data-pipelines/             ← DuckDB-centric data stack (dlt, sqlmesh, polars, marimo)
~/.agents/skills/sprites/                    ← manage remote Sprites (Fly.io microVMs)
~/.claude/skills/bootstrap-project → ../../.agents/skills/bootstrap-project
~/.codex/skills/bootstrap-project → ../../.agents/skills/bootstrap-project
(same pattern for all skills)
```

## Editing

**Global instructions** — edit `agents/.agents/AGENTS.md`. The stow symlinks ensure both agents pick up changes automatically.

**Adding a skill** — create `agents/.agents/skills/<name>/SKILL.md` with YAML frontmatter (`name`, `description`), then add the corresponding `npx -y skills add` command to the `install_skills` function in `install.sh`. The `.stow-local-ignore` file already excludes skills from stow.

**Adding an MCP server** — add the `claude mcp add` command (HTTP transport) to the MCP section in `install.sh`. OAuth servers use `--transport http`. PAT-based servers use `add-json` with an `Authorization` header.

## Deploying

```bash
# Stow the agents package (deploys AGENTS.md, Claude settings)
stow --no-folding -R -t "$HOME" agents

# Install skills and configure MCP servers (run after stow)
./install.sh
```

Or just run `./install.sh` which handles everything.

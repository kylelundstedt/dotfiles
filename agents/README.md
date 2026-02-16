# agents

Shared infrastructure for running Claude Code (primary) and Codex CLI (backup) with a single set of instructions, skills, and MCP servers. Both agents read the same `AGENTS.md`, use the same skills, and connect to the same MCP servers — so switching between them is seamless.

See `agent_docs/agents-recommendations.md` for dual-agent workflow patterns (draft/review, parallel debugging, task routing).

## What gets deployed

Stow deploys the core agent infrastructure:

```
~/.agents/AGENTS.md                          ← canonical global instructions
~/.agents/mcp/bin/                           ← shared MCP wrapper scripts + .env references
~/.claude/CLAUDE.md → ../.agents/AGENTS.md   ← so Claude Code reads the canonical file
~/.codex/AGENTS.md  → ../.agents/AGENTS.md   ← so Codex reads the canonical file
```

Skills are **copied** (not stow-symlinked) by `install.sh` into `~/.agents/skills/`, then symlinked into both `~/.claude/skills/` and `~/.codex/skills/`. This is because Codex doesn't resolve multi-level symlinks when scanning for skills.

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

**Adding a skill** — create `agents/.agents/skills/<name>/SKILL.md` with YAML frontmatter (`name`, `description`), then add the skill name to the `for skill in ...` loop in `install.sh` (appears twice — in `install_skills` and in the post-stow section). The `.stow-local-ignore` file already excludes skills from stow.

**Adding an MCP server** — place the wrapper script and any companion `.env` file in `agents/.agents/mcp/bin/`, then add the server name + wrapper path to the `mcp_specs` array in `install.sh`.

## Deploying

```bash
# Stow the agents package (deploys AGENTS.md, MCP wrappers, Claude settings)
stow --no-folding -R -t "$HOME" agents

# Copy skills and create symlinks (run after stow)
./install.sh
```

Or just run `./install.sh` which handles everything.

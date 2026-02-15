# agents (stow package)

Deploys shared agent infrastructure to `~/` via GNU Stow.

## What gets deployed

```
~/.agents/AGENTS.md                          ← canonical global instructions
~/.agents/skills/bootstrap-project/          ← stow-managed skill
~/.claude/CLAUDE.md → ../.agents/AGENTS.md   ← so Claude Code reads the canonical file
~/.codex/AGENTS.md  → ../.agents/AGENTS.md   ← so Codex reads the canonical file
```

## Editing

Edit `agents/.agents/AGENTS.md` to change global agent instructions. The symlinks ensure both Claude Code and Codex pick up changes automatically.

To add a new stow-managed skill, create a directory under `agents/.agents/skills/<name>/` with a `SKILL.md` file, then update `install.sh` to call `link_skill <name>`.

## Deploying

```bash
stow --no-folding -R -t "$HOME" agents
```

Or run `./install.sh` which stows all packages.

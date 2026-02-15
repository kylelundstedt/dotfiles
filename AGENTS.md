# Dotfiles

GNU Stow–managed dotfiles and AI agent platform for macOS and Linux. Each top-level directory is a stow package targeting `~/`.

## Key Commands

- Install everything: `./install.sh` (or `./install.sh --no-prompt` for non-interactive)
- Test on Linux: `./test-linux.sh` (OrbStack VM) or the Docker one-liner in that script
- Stow a single package: `stow --no-folding -R -t "$HOME" <package>`
- Dry-run stow: `stow --no-folding -R -n -t "$HOME" <package>`

## Conventions

- Always use `--no-folding` with stow so individual files are symlinked, not directories.
- Secrets stay out of committed files — use 1Password (`op run`) or `.gitignore`d local configs.
- `agents/.agents/AGENTS.md` is the canonical global agent instruction file. `agents/.claude/CLAUDE.md` and `agents/.codex/AGENTS.md` are symlinks to it.
- Skills live in `agents/.agents/skills/` (stow-managed) or `~/.agents/skills/` (git-cloned). Both `~/.claude/skills/` and `~/.codex/skills/` symlink into `~/.agents/skills/`.
- MCP server wrappers live in `claude/bin/` and use `op run` to inject 1Password secrets at runtime. Servers: github-home, github-work, motherduck, dlt, tigris.
- Local config files (`aws/.aws/config`, `ssh/.ssh/config`, `git/.gitconfig_local`) are gitignored and created from examples or prompts during install.

## Structure

| Package | Purpose |
|---------|---------|
| `1Password/` | 1Password SSH agent config (macOS) |
| `agents/` | Stow package — deploys agent infrastructure to `~/` (`AGENTS.md`, Claude/Codex symlinks, skills) |
| `agent_docs/` | Reference docs for this repo — agent setup plans, platform notes, secret management (not stowed) |
| `aws/` | AWS CLI configuration (Linux) |
| `claude/` | Claude Code settings, MCP server wrappers (`op run`), `.env` secret references |
| `git/` | Git configuration with OS-specific includes |
| `homebrew/` | Brewfiles for macOS + Linux |
| `python/` | Python project dependencies via uv (not stowed) |
| `ssh/` | SSH client configuration (macOS) |
| `starship/` | Starship prompt configuration |
| `vscode/` | VS Code settings and extensions (macOS) |
| `zsh/` | Zsh configuration, aliases, completions |

## install.sh

The install script self-bootstraps from a bare machine. Key responsibilities:

- Detects OS and installs packages (Homebrew on macOS; apt, dnf, pacman, yum, zypper on Linux)
- Installs CLI tools in parallel (starship, carapace, uv alongside apt packages)
- Configures MCP servers for Claude Code via `claude mcp add`
- Installs and symlinks agent skills for both Claude and Codex
- Stows all packages and links stow-managed skills post-stow
- Handles root, sudo, and non-interactive modes for containers and CI
- Idempotent — safe to re-run

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
- MCP server wrappers live in `agents/.agents/mcp/bin/` and use `op run` to inject 1Password secrets at runtime. Servers: github-home, github-work, motherduck, dlt, tigris.
- Local config files (`aws/.aws/config`, `ssh/.ssh/config`, `git/.gitconfig_local`) are gitignored and created from examples or prompts during install.

## Structure

| Package | Purpose |
|---------|---------|
| `1Password/` | 1Password SSH agent config (macOS) |
| `agents/` | Agent infrastructure — `AGENTS.md`, Claude/Codex symlinks, skills, MCP server wrappers (`op run`), Claude Code settings |
| `agent_docs/` | Reference docs for this repo — agent setup plans, platform notes, secret management (not stowed) |
| `aws/` | AWS CLI configuration (Linux) |
| `git/` | Git configuration with OS-specific includes |
| `homebrew/` | Brewfiles for macOS + Linux |
| `launchd/` | LaunchAgents for macOS — daily repo sync (stowed) |
| `ssh/` | SSH client configuration (macOS) |
| `starship/` | Starship prompt configuration |
| `vscode/` | VS Code settings and extensions (macOS) |
| `sync-repos.sh` | Clones/fetches all GitHub repos for personal and work accounts |
| `zsh/` | Zsh configuration, aliases, completions |

## install.sh

The install script self-bootstraps from a bare machine. Structured into three composable layers controlled by `--only`:

- **Shell layer** (universal): prerequisites, core CLI tools, starship/carapace/uv, stow shell packages (`git`, `zsh`, `starship`), git config, set default shell
- **Agent layer** (local + interactive microVM): 1Password CLI, Claude Code CLI, Codex CLI, MCP server config, skills install, stow `agents` package
- **Apps layer** (local machine only): Homebrew casks, npm globals, VS Code extensions, Sprite CLI, Apple Containers CLI, LaunchAgents, stow platform-specific packages

**Auto-detection:** without `--only`, the script detects context (local, Sprite microVM, container) and picks appropriate layers. Override with `--only shell,agents` etc.

**Flags:** `--only <layers>`, `--background-apps`, `--dry-run`, `--no-prompt`, `--include-heavy`, `--skip-stow`, `--interactive`

Key properties:
- Idempotent — safe to re-run
- Handles root, sudo, and non-interactive modes for containers and CI
- `--background-apps` forks the apps layer into the background after shell + agents complete

# Dotfiles

GNU Stow–managed dotfiles and AI agent platform for macOS and Linux. Each top-level directory is a stow package targeting `~/`.

## Key Commands

- Install everything: `./install.sh`
- Install with macOS apps (casks, Mac App Store): `./install.sh --apps`
- Skip agent setup: `./install.sh --skip-agents`
- Test on Linux: `./test-install.sh` (Apple Container, Sprite, exe.dev)
- Stow a single package: `stow --no-folding -R -t "$HOME" <package>`
- Dry-run stow: `stow --no-folding -R -n -t "$HOME" <package>`

## Conventions

- Always use `--no-folding` with stow so individual files are symlinked, not directories.
- Secrets stay out of committed files — use 1Password (`op run`) or `.gitignore`d local configs.
- `agents/.agents/AGENTS.md` is the canonical global agent instruction file. `agents/.claude/CLAUDE.md` and `agents/.codex/AGENTS.md` are symlinks to it.
- Skills live in `agents/.agents/skills/` (stow-managed) or `~/.agents/skills/` (git-cloned). Both `~/.claude/skills/` and `~/.codex/skills/` symlink into `~/.agents/skills/`.
- MCP servers use remote HTTP transport. OAuth servers (motherduck, tigris) work everywhere. GitHub servers (github-home, github-work) use PATs from 1Password (macOS only).
- Local config files (`aws/.aws/config`, `ssh/.ssh/config`, `git/.gitconfig_local`) are gitignored and created from examples or prompts during install.

## Structure

| Package           | Purpose                                                                                          |
| ----------------- | ------------------------------------------------------------------------------------------------ |
| `1Password/`      | 1Password SSH agent config (macOS)                                                               |
| `agents/`         | Agent infrastructure — `AGENTS.md`, Claude/Codex symlinks, skills, Claude Code settings          |
| `agent_docs/`     | Reference docs for this repo — agent setup plans, platform notes, secret management (not stowed) |
| `aws/`            | AWS CLI configuration (Linux)                                                                    |
| `ghostty/`        | Ghostty terminal configuration (macOS)                                                           |
| `git/`            | Git configuration with OS-specific includes                                                      |
| `homebrew/`       | Brewfile for macOS casks and Mac App Store apps (CLI tools installed directly in install.sh)     |
| `launchd/`        | LaunchAgents for macOS — daily repo sync (stowed)                                                |
| `ssh/`            | SSH client configuration                                                                         |
| `starship/`       | Starship prompt configuration                                                                    |
| `vscode/`         | VS Code settings and extensions (macOS)                                                          |
| `sync-repos.sh`   | Clones/fetches all GitHub repos for personal and work accounts                                   |
| `test-install.sh` | Tests install.sh across Apple Container, Sprite, and exe.dev                                     |
| `zed/`            | Zed editor settings (macOS)                                                                      |
| `zsh/`            | Zsh configuration, aliases, completions                                                          |

## install.sh

The install script sets up a machine from scratch. It self-bootstraps — when piped via `curl | bash`, it installs git, clones the repo to `~/dotfiles`, and re-execs from the cloned copy. If already running from inside the repo, it skips straight to the install steps:

1. **Bootstrap** — (only when not in repo) install git, clone to `~/dotfiles`, re-exec
2. **System deps** — stow, zsh, git, curl (apt on Linux, Homebrew on macOS)
3. **CLI tools** — installed in parallel via curl scripts and GitHub release binaries to `~/.local/bin` (starship, uv, atuin, zoxide, direnv, tigris, fnm, bat, fzf, rg, jq, yq, gh, duckdb, carapace)
4. **Node** — via fnm (LTS)
5. **Git config** — OS include file, SSH multiplexing for GitHub, interactive prompt for user name/email
6. **Shell** — set default shell to zsh
7. **Stow** — all packages
8. **Tailscale** — install, start tailscaled (Sprite Service / systemd / bare nohup), authenticate with `--ssh`. Detects environment: Sprites use `sprite-env services create` so tailscaled survives sleep/wake; systemd uses `systemctl enable --now`; Apple Containers and exe.dev use `nohup tailscaled --tun=userspace-networking`.
9. **Agents** — Claude Code CLI, Codex CLI, 1Password CLI (Linux), MCP server registration (remote HTTP), agent skills
10. **Apps** (only with `--apps`) — `brew bundle` for casks/MAS apps, Sprite CLI, Apple Container CLI, LaunchAgents

**Flags:** `--apps`, `--dry-run`, `--skip-stow`, `--skip-agents`

Key properties:

- Idempotent — safe to re-run (each tool checks `need <cmd>` before installing)
- Works on macOS and Linux (apt-based)
- Non-interactive mode auto-enabled when not attached to a TTY

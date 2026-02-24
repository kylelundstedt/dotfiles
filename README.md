# Dotfiles

One command to set up a fully configured development environment on macOS or Linux — shell, git, AI coding agents, and dev tools.

## What You Get

**AI agent platform** — [Claude Code](https://docs.anthropic.com/en/docs/claude-code) and [Codex CLI](https://github.com/openai/codex) with a shared instruction system (`AGENTS.md`), cross-agent skills (`bootstrap-project`, `data-pipelines`, `sprites`, `mviz`, `find-skills`), five MCP servers (GitHub home/work, MotherDuck, dlt, Tigris) with [1Password secret injection](agent_docs/secrets.md), and a convention for per-project agent context (`agent_docs/`)

**Shell** — Zsh with [Starship](https://starship.rs/) prompt, [Atuin](https://atuin.sh/) history sync, [Zoxide](https://github.com/ajeetdsouza/zoxide) smart `cd`, [Carapace](https://carapace.sh/) completions, and [Direnv](https://direnv.net/)

**Modern CLI replacements** — `cat` → [bat](https://github.com/sharkdp/bat), `grep` → [ripgrep](https://github.com/BurntSushi/ripgrep), `cd` → [zoxide](https://github.com/ajeetdsouza/zoxide)

**Dev tools** — Git with 1Password SSH signing, AWS CLI v2, DuckDB, Python via [uv](https://docs.astral.sh/uv/)

**`zp` — Zed project launcher** — Opens projects in Zed across local macOS, [Apple Containers](https://developer.apple.com/documentation/containerization), and [Fly.io Sprites](https://fly.io/docs/sprites/). Project-first: `zp gitlake` finds and opens, `zp owner/name --backend container --machine dev` creates a container, bootstraps dotfiles, clones the repo, and opens Zed — fully non-interactive.

---

## Quick Start

```bash
curl -fsSL https://raw.githubusercontent.com/kylelundstedt/dotfiles/master/install.sh | bash
```

The script self-bootstraps from a bare machine: detects your OS, installs packages (Homebrew on macOS, apt/dnf/pacman/zypper on Linux), configures agent tooling (MCP servers, skills for both Claude and Codex), and symlinks all configuration into place. It's idempotent — safe to run again.

To also install GUI apps (macOS casks, Mac App Store apps) or Linux extras:

```bash
curl -fsSL https://raw.githubusercontent.com/kylelundstedt/dotfiles/master/install.sh | bash -s -- --include-heavy
```

Or clone and run manually:

```bash
git clone https://github.com/kylelundstedt/dotfiles ~/dotfiles
cd ~/dotfiles
./install.sh                          # All layers (auto-detected)
./install.sh --only shell,agents      # Shell + agents only (microVM)
./install.sh --only shell --no-prompt # Shell only (non-interactive microVM)
./install.sh --include-heavy          # + macOS casks/MAS apps or Linux extras
./install.sh --background-apps        # Fork apps layer to background
```

**Flags:** `--only <layers>`, `--background-apps`, `--dry-run`, `--no-prompt`, `--include-heavy`, `--skip-stow`, `--interactive`

**Layers:** `shell` (CLI tools, shell config), `agents` (Claude/Codex, MCP servers, skills), `apps` (brew casks, VS Code, Sprite CLI, Apple Containers CLI)

Auto-detection picks layers based on context: local machine gets all three, Sprite microVMs get shell + agents (or shell-only if non-interactive), containers get shell only. Override with `--only`.

That's it — your shell, git, agent tooling, and dev tools are all configured. Start using them:

```bash
cd ~/dotfiles
claude    # or codex — AGENTS.md is already in place
```

From here, the agent can walk you through customization (git identity, AWS, SSH) or you can browse `agent_docs/` for details on secrets, platform setup, and agent workflows.

To bring the same agent setup to another project, use the `/bootstrap-project` skill inside Claude or Codex. It reads the repo (README, manifest, CI config, directory structure) and generates a tailored `AGENTS.md` with the project's stack, commands, and conventions — plus a `CLAUDE.md` symlink and an `agent_docs/` directory for supplementary context.

---

## How It Works

Configuration is managed with [GNU Stow](http://www.gnu.org/software/stow/), which creates symlinks from this repo into your home directory. Each top-level directory is a "package" that gets stowed independently:

| Directory       | Purpose                                                                                               | Stow Target                           | Platform |
| --------------- | ----------------------------------------------------------------------------------------------------- | ------------------------------------- | -------- |
| `1Password/`    | 1Password SSH agent config                                                                            | `~/.config/1Password/`                | macOS    |
| `agents/`       | Agent infrastructure — `AGENTS.md`, Claude/Codex symlinks, skills, MCP wrappers, Claude Code settings | `~/`                                  | Both     |
| `agent_docs/`   | Reference docs for this repo — agent setup plans, platform notes, secret management                   | N/A (not stowed)                      | Both     |
| `aws/`          | AWS CLI configuration                                                                                 | `~/.aws/`                             | Linux    |
| `git/`          | Git configuration with OS-specific includes                                                           | `~/`                                  | Both     |
| `homebrew/`     | Brewfile(s) for macOS + Linux                                                                         | `~/`                                  | Both     |
| `launchd/`      | LaunchAgents — daily repo sync                                                                        | `~/Library/LaunchAgents/`             | macOS    |
| `ssh/`          | SSH client configuration                                                                              | `~/.ssh/`                             | Both     |
| `starship/`     | Starship prompt configuration                                                                         | `~/.config/`                          | Both     |
| `scripts/`      | Utility scripts (e.g., `open-project.sh` for Zed + Ghostty tiling)                                    | N/A (not stowed)                      | macOS    |
| `vscode/`       | VS Code IDE settings & keybindings                                                                    | `~/Library/Application Support/Code/` | macOS    |
| `sync-repos.sh` | Clones/fetches all GitHub repos for personal and work accounts                                        | N/A (standalone script)               | Both     |
| `zed/`          | Zed editor settings + `zp` project launcher with pluggable backends                                   | `~/.config/zed/`, `~/.local/bin/`     | macOS    |
| `zsh/`          | Zsh shell configuration                                                                               | `~/`                                  | Both     |

Git uses a generated OS include so only one platform-specific file is active:

```
~/.gitconfig                 # Main config with include directives
├── ~/.gitconfig_common      # Shared configuration
├── ~/.gitconfig_local       # User-specific (name, email) - gitignored
├── ~/.gitconfig_os_local    # Managed by install.sh (macOS or Linux include)
├── ~/.gitconfig_macos       # macOS-specific (1Password SSH signing)
└── ~/.gitconfig_linux       # Linux-specific (micro editor)
```

---

## Agent Platform

Both Claude Code and Codex CLI share a single instruction file (`AGENTS.md`) deployed via stow symlinks. The install script configures everything for both agents automatically.

**Shared instructions** — `agents/.agents/AGENTS.md` is the canonical source. Stow creates `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md` as symlinks so both agents read the same file.

**Skills** — Installed to `~/.agents/skills/` and symlinked into both `~/.claude/skills/` and `~/.codex/skills/`:

| Skill               | Source                                                      | Purpose                                                                   |
| ------------------- | ----------------------------------------------------------- | ------------------------------------------------------------------------- |
| `bootstrap-project` | This repo                                                   | Scaffolds per-project `AGENTS.md`, `CLAUDE.md` symlink, and `agent_docs/` |
| `data-pipelines`    | This repo                                                   | DuckDB-centric data stack — dlt, sqlmesh, polars, marimo, uv              |
| `sprites`           | This repo                                                   | Manage remote Sprites (Fly.io microVMs) from local machine                |
| `mviz`              | [matsonj/mviz](https://github.com/matsonj/mviz)             | Chart and report builder                                                  |
| `find-skills`       | [vercel-labs/skills](https://github.com/vercel-labs/skills) | Skill discovery and installation                                          |

**MCP servers** — Shared wrappers in `agents/.agents/mcp/bin/` use `op run` to inject 1Password secrets at runtime. `install.sh` registers them for both Claude and Codex:

| Server        | Purpose                       |
| ------------- | ----------------------------- |
| `github-home` | GitHub API (personal account) |
| `github-work` | GitHub API (work account)     |
| `motherduck`  | MotherDuck / DuckDB           |
| `dlt`         | dlt pipeline tools            |
| `tigris`      | Tigris object storage         |

**Per-project context** — Use the `/bootstrap-project` skill in any repo to generate a tailored `AGENTS.md`, a `CLAUDE.md` symlink, and an `agent_docs/` directory.

---

## After Installation

**Customize local configs** (gitignored, won't be committed):

- **Git**: edit `~/dotfiles/git/.gitconfig_local` (gitignored personal name/email)
- **AWS**: `~/dotfiles/aws/.aws/config` — update SSO URLs, account IDs, regions
- **SSH**: `~/dotfiles/ssh/.ssh/config` — add your hosts

**Reload after changes:**

```bash
source ~/.zshrc                                   # Shell config
brew bundle --file=~/dotfiles/homebrew/Brewfile    # Homebrew packages (macOS)
atuin sync                                        # Shell history
```

---

## Troubleshooting

**Shell not switching to Zsh** — Check if zsh is in `/etc/shells` and run `chsh -s $(which zsh)`

**Starship not loading** — Ensure the starship binary is in PATH

**Git SSH signing not working** — Verify 1Password SSH agent is running and the `identityagent` path is correct in `.gitconfig_macos`

**Homebrew failures** — Run `brew doctor` and ensure Xcode Command Line Tools are installed: `xcode-select --install`

---

## Further Reading

- [Secret Management with 1Password](agent_docs/secrets.md) — `op run` pattern, MCP server wrappers
- [Linux](agent_docs/linux.md) — platform notes, OrbStack, local sprites (Apple Container), Fly.io Sprites, Docker testing, cloud-init
- [Adding Rules and Skills](agent_docs/agents-advanced.md) — when and how to extend agent configuration beyond `AGENTS.md`
- [Agent Recommendations](agent_docs/agents-recommendations.md) — dual-agent operating patterns, routing defaults, maintenance checklists

---

## Thanks

- [@jeffwidman](https://github.com/jeffwidman/dotfiles)
- More info:
  - http://brandon.invergo.net/news/2012-05-26-using-gnu-stow-to-manage-your-dotfiles.html
  - http://kianmeng.org/blog/2014/03/08-using-gnu-stow-to-manage-your-dotfiles/

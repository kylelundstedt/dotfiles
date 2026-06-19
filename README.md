# Dotfiles

One command to set up a fully configured development environment on macOS or Linux — shell, git, AI coding agents, and dev tools.

## What You Get

**AI agent platform** — [Claude Code](https://docs.anthropic.com/en/docs/claude-code) and [Codex CLI](https://github.com/openai/codex) with a shared instruction system (`AGENTS.md`), cross-agent skills (`join-tailnet`, `upgrade-vm`, `apple-containers`, `sprites-dev`, `mviz`, `find-skills`), four remote MCP servers (GitHub home/work, MotherDuck, Tigris) via HTTP transport, and a convention for per-project agent context (`agent_docs/`)

**Shell** — Zsh with [Starship](https://starship.rs/) prompt, [Atuin](https://atuin.sh/) history sync, [Zoxide](https://github.com/ajeetdsouza/zoxide) smart `cd`, [Carapace](https://carapace.sh/) completions, and [Direnv](https://direnv.net/)

**Modern CLI replacements** — `cat` → [bat](https://github.com/sharkdp/bat), `grep` → [ripgrep](https://github.com/BurntSushi/ripgrep), `cd` → [zoxide](https://github.com/ajeetdsouza/zoxide)

**Dev tools** — Git with 1Password SSH signing, AWS CLI v2, DuckDB, Python via [uv](https://docs.astral.sh/uv/)

**Remote development** — Primary platform is [exe.dev](https://exe.dev) with a custom image (`iv-image`) that bakes in team agent config, MCP servers, and skills. Personal dotfiles (`install.sh`) layer on top for shell, CLI tools, and personal MCP servers. Zed's [remote development](https://zed.dev/docs/remote-development) connects over SSH. Tailscale provides stable hostnames, and SSH agent forwarding from the Mac's 1Password agent enables git clone/push and commit signing — no tokens needed on the VMs.

---

## Quick Start

```bash
curl -fsSL https://raw.githubusercontent.com/kylelundstedt/dotfiles/master/install.sh | bash
```

The script self-bootstraps from a bare machine: installs git if needed, clones the repo to `~/dotfiles`, then re-runs from the cloned copy. From there it detects your OS, installs packages (Homebrew on macOS, apt on Linux), configures agent tooling (MCP servers, skills for both Claude and Codex), and symlinks all configuration into place. It's idempotent — safe to run again.

Or clone and run manually:

```bash
git clone https://github.com/kylelundstedt/dotfiles ~/dotfiles
cd ~/dotfiles
./install.sh                 # CLI tools, shell, git, stow, agents
./install.sh --apps          # + macOS casks, Mac App Store apps, Sprite CLI
./install.sh --skip-agents   # Skip Claude/Codex/MCP setup
./install.sh --skip-stow     # Skip stow step
./install.sh --dry-run       # Preview stow changes
```

**Flags:** `--apps`, `--dry-run`, `--skip-stow`, `--skip-agents`, `--tailscale-ssh`

**Hosts:** `klundstedt-mini` is the always-on Mac mini SSH target — install it with `--tailscale-ssh` on the **first** run so it runs open-source `tailscaled` (system daemon via `sudo brew services`) for incoming Tailscale SSH. After that, the brew formula is auto-detected and every subsequent `./install.sh` maintains it without the flag. Other macOS machines use the standard Tailscale app and don't need the flag.

`install.sh` never upgrades the tailscale formula — version bumps are manual. Since `tailscaled` runs as a root system daemon, the upgrade ritual on this host is: `brew upgrade tailscale` → `sudo brew services restart tailscale` (clears CLI/daemon version skew) → `sudo rm -rf /opt/homebrew/Cellar/tailscale/<old-versions>` (`brew cleanup` can't remove the root-owned old kegs on its own).

That's it — your shell, git, agent tooling, and dev tools are all configured. Start using them:

```bash
cd ~/dotfiles
claude    # or codex — AGENTS.md is already in place
```

From here, the agent can walk you through customization (git identity, AWS, SSH) or you can browse `agent_docs/` for details on secrets, platform setup, and agent workflows.

---

## How It Works

Configuration is managed with [GNU Stow](http://www.gnu.org/software/stow/), which creates symlinks from this repo into your home directory. Each top-level directory is a "package" that gets stowed independently:

| Directory         | Purpose                                                                                               | Stow Target                           | Platform |
| ----------------- | ----------------------------------------------------------------------------------------------------- | ------------------------------------- | -------- |
| `1Password/`      | 1Password SSH agent config                                                                            | `~/.config/1Password/`                | macOS    |
| `agents/`         | Agent infrastructure — `AGENTS.md`, Claude/Codex symlinks, skills, MCP wrappers, Claude Code settings | `~/`                                  | Both     |
| `agent_docs/`     | Reference docs for this repo — agent setup plans, platform notes, secret management                   | N/A (not stowed)                      | Both     |
| `aws/`            | AWS CLI configuration                                                                                 | `~/.aws/`                             | Linux    |
| `ghostty/`        | Ghostty terminal configuration                                                                        | `~/.config/ghostty/`                  | macOS    |
| `git/`            | Git configuration with OS-specific includes                                                           | `~/`                                  | Both     |
| `homebrew/`       | Brewfile for macOS casks and Mac App Store apps                                                       | `~/`                                  | macOS    |
| `launchd/`        | LaunchAgents — daily repo sync                                                                        | `~/Library/LaunchAgents/`             | macOS    |
| `ssh/`            | SSH client configuration                                                                              | `~/.ssh/`                             | Both     |
| `starship/`       | Starship prompt configuration                                                                         | `~/.config/`                          | Both     |
| `vscode/`         | VS Code IDE settings & keybindings                                                                    | `~/Library/Application Support/Code/` | macOS    |
| `sync-repos.sh`   | Clones/fetches all GitHub repos for personal and work accounts                                        | N/A (standalone script)               | Both     |
| `test-install.sh` | Tests install.sh across Apple Container, Sprite, and exe.dev                                          | N/A (standalone script)               | macOS    |
| `zed/`            | Zed editor settings                                                                                   | `~/.config/zed/`                      | macOS    |
| `zsh/`            | Zsh shell configuration                                                                               | `~/`                                  | Both     |

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

**Two levels of instructions:**

- **Global** (`agents/.agents/AGENTS.md`) — rules for every repo: honesty, communication, code conventions, skill usage. Stow creates `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md` as symlinks so both agents read the same file.
- **Per-project** (`AGENTS.md` at repo root) — context specific to each repo. In this repo, `CLAUDE.md` is a symlink to `AGENTS.md`.

**Skills** — Installed by `npx -y skills add -g -y` (the [skills CLI](https://github.com/vercel-labs/skills)) directly into `~/.claude/skills/` and `~/.codex/skills/`. Canonical source files live in `agents/.agents/skills/`:

| Skill              | Source                                                                                  | Purpose                                                 |
| ------------------ | --------------------------------------------------------------------------------------- | ------------------------------------------------------- |
| `join-tailnet`     | This repo                                                                               | Join an exe.dev VM to the Tailscale tailnet on demand   |
| `upgrade-vm`       | This repo                                                                               | Upgrade an exe.dev VM to a newer image version          |
| `apple-containers` | This repo                                                                               | Apple Container VM lifecycle on macOS (back-burnered)   |
| `sprites-dev`      | This repo                                                                               | Manage remote Sprites (Fly.io microVMs) — back-burnered |
| `mviz`             | [matsonj/mviz](https://github.com/matsonj/mviz)                                         | Chart and report builder                                |
| `find-skills`      | [vercel-labs/skills](https://github.com/vercel-labs/skills)                             | Skill discovery and installation                        |
| 5 Tigris skills    | [tigrisdata/tigris-agents-plugins](https://github.com/tigrisdata/tigris-agents-plugins) | Tigris CLI — auth, buckets, objects, access keys, IAM   |
| DuckDB skills      | [duckdb/duckdb-skills](https://github.com/duckdb/duckdb-skills)                         | DuckDB query, file reading, database management         |
| `quarto-authoring` | [posit-dev/skills](https://github.com/posit-dev/skills)                                 | Quarto document authoring                               |
| `brand-yml`        | [posit-dev/skills](https://github.com/posit-dev/skills)                                 | Brand styling for Shiny/Quarto                          |
| `marimo-notebook`  | [marimo-team/skills](https://github.com/marimo-team/skills)                             | Write marimo notebooks                                  |
| `marimo-batch`     | [marimo-team/skills](https://github.com/marimo-team/skills)                             | Prepare marimo notebooks for scheduled runs             |
| `marimo-pair`      | [marimo-team/marimo-pair](https://github.com/marimo-team/marimo-pair)                   | Drop agents inside running marimo notebook sessions     |
| `archil-guide`     | [archil.com](https://archil.com/skill.md)                                               | Archil distributed filesystem setup and usage           |

Invoke a skill by typing `/skill-name` in Claude Code or Codex (e.g. `/join-tailnet`).

**MCP servers** — Remote HTTP transport. OAuth servers (MotherDuck, Tigris) work on all environments after initial browser auth. GitHub servers use PATs resolved from 1Password at install time (macOS only). `install.sh` registers them for Claude Code:

| Server        | Purpose                       | Auth  |
| ------------- | ----------------------------- | ----- |
| `motherduck`  | MotherDuck / DuckDB           | OAuth |
| `tigris`      | Tigris object storage         | OAuth |
| `github-home` | GitHub API (personal account) | PAT   |
| `github-work` | GitHub API (work account)     | PAT   |

**Per-project context** — Create an `AGENTS.md` at the repo root with project-specific conventions, a `CLAUDE.md` symlink to it, and an `agent_docs/` directory for supplementary context.

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

**Update already-running VMs** — Configs are symlinks into `~/dotfiles`, so a plain `git pull` makes edits to _existing_ files take effect on the next new shell — no `install.sh` re-run needed. The repo is public, so pulling needs no credentials (only `git push` does):

```bash
# one VM
ssh <vm> 'cd ~/dotfiles && git pull --ff-only'

# fan out over the tailnet (parallel-safe — not rate-limited like *.exe.xyz)
for vm in <vm1> <vm2> ...; do ssh "$vm" 'cd ~/dotfiles && git pull --ff-only'; done
```

Re-run `install.sh` on a VM only when a pull _adds or removes_ files (new skills, new stow packages) so stow can reconcile the symlinks. Use `./install.sh --skip-agents` for just the stow step — it skips the slower agent/MCP setup (which needs a local browser for some OAuth flows and is best run from the Mac).

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

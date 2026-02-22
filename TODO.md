# TODO

## install.sh rewrite
- [x] Test container backend (`./test-linux.sh container`) — verify root without sudo
- [x] Test sprite backend (`./test-linux.sh sprite`) — verify non-root with sudo
- [ ] Test on macOS (clean `~/.local/bin`) — verify GitHub release binary matching for arm64
- [ ] Test `--apps` flag (brew bundle casks + MAS apps)

## Stale references (claude/ → agents/ merge)
- [x] `.githooks/pre-commit:17` — update `claude/bin/` grep to `agents/.agents/mcp/bin/`
- [x] `zsh/.zshrc:86` — fix comment referencing `~/dotfiles/claude/bin/`

## AGENTS.md drift
- [x] Sync `agents/.agents/AGENTS.md` with private global — add Data Work, Formatters, `/data-pipelines`, `/sprites`
- [x] Fix git push rule contradiction — stow version says "push after committing", should match "push when asked"

## Dead or inconsistent config
- [x] `zsh/.zshrc:90-92` — node PATH block replaced by fnm eval
- [x] `homebrew/Brewfile:7` — direnv now curl-installed on all platforms
- [ ] `vscode/` settings reference Warp.app and hardcoded Snowflake path. Update for Ghostty or remove.

## Unmanaged state
- [x] `data-pipelines` and `sprites` skills — added to `agents/.agents/skills/` upstream
- [x] `.githooks/pre-commit` — deleted upstream

## zop (unified Zed launcher)
- [x] Create `zop` dispatcher + backend interface in `zed/.local/bin/`
- [x] Implement local, container, sprite backends
- [x] Delete `scripts/` directory, remove PATH entry from `.zshrc`
- [x] Test container backend with Apple Container (macOS 26)
- [x] Test sprite backend with real Sprite
- [x] Redesign: combined target picker, required backend + project, provisioning ([+ new] / [+ clone])
- [x] Test redesigned flow with container and sprite backends
- [x] Bootstrap new remote machines with dotfiles clone + `install.sh --no-prompt` after provisioning
- [x] Fix install.sh for root containers (missing `sudo`)
- [ ] Add self-clone for curl one-liner bootstrap
- [ ] Add Spotlight/Shortcuts integration (osascript fallback when no tty)
- [ ] Build shared base image (Dockerfile) for container + sprite backends

## Minor
- [x] `homebrew/Brewfile:105` — corrupted text `id: 1481302432ple` (fixed in Brewfile rewrite)
- [ ] `agent_docs/secrets.md` — remove `--no-masking` flag not in actual wrappers
- [ ] `git/.gitconfig_common:27` — remove empty `[credential]` section

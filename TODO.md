# TODO

## Stale references (claude/ → agents/ merge)
- [x] `.githooks/pre-commit:17` — update `claude/bin/` grep to `agents/.agents/mcp/bin/`
- [x] `zsh/.zshrc:86` — fix comment referencing `~/dotfiles/claude/bin/`

## AGENTS.md drift
- [x] Sync `agents/.agents/AGENTS.md` with private global — add Data Work, Formatters, `/data-pipelines`, `/sprites`
- [x] Fix git push rule contradiction — stow version says "push after committing", should match "push when asked"

## Dead or inconsistent config
- [ ] `zsh/.zshrc:90-92` — node@22 PATH block doesn't match Brewfile's `node` (latest). Align or remove.
- [ ] `homebrew/Brewfile:7` — direnv commented out on macOS but hooked in `.zshrc` and listed in README
- [ ] `vscode/` settings reference Warp.app and hardcoded Snowflake path. Update for Ghostty or remove.

## Unmanaged state
- [x] `data-pipelines` and `sprites` skills — added to `agents/.agents/skills/` upstream
- [x] `.githooks/pre-commit` — deleted upstream

## Minor
- [ ] `homebrew/Brewfile:105` — corrupted text `id: 1481302432ple`
- [ ] `agent_docs/secrets.md` — remove `--no-masking` flag not in actual wrappers
- [ ] `git/.gitconfig_common:27` — remove empty `[credential]` section

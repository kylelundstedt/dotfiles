# TODO

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

## Minor
- [x] `homebrew/Brewfile:105` — corrupted text `id: 1481302432ple` (fixed in Brewfile rewrite)
- [ ] `agent_docs/secrets.md` — remove `--no-masking` flag not in actual wrappers
- [ ] `git/.gitconfig_common:27` — remove empty `[credential]` section

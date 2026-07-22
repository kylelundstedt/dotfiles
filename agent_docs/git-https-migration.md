# Git HTTPS migration

Status: **complete** (2026-07-22).

## Desired end state

Git transport uses HTTPS everywhere:

- GitHub is the canonical source of truth for both repositories.
- `klundstedt-mini` authors and merges `kylelundstedt/dotfiles` and
  `kylelundstedt/iv-image` using GitHub CLI credentials and HTTPS remotes.
- Linux compatibility canaries are created on demand, consume both repositories
  read-only, and are deleted after validation.
- exe.dev project VMs push only through their scoped HTTPS GitHub integrations;
  no Git PAT or signing key is stored on a VM.
- dotfiles and iv-image remain read-only consumers on ordinary project VMs.
- Git commit signing and SSH transport are not dependencies for Git operations.

## Affected source and hosts

| Area                           | Change                                                                         |
| ------------------------------ | ------------------------------------------------------------------------------ |
| `git/.gitconfig_{macos,linux}` | Remove SSH Git transport and SSH-signing configuration.                        |
| `zsh/.zshrc`                   | Remove forwarded-agent commit-signing activation.                              |
| `install.sh`                   | Clear stale local signing settings; authenticate GitHub CLI for HTTPS.         |
| `sync-repos.sh`                | Use direct HTTPS remotes without SSH rewrite workarounds.                      |
| Documentation                  | Remove claims that 1Password SSH forwarding signs or pushes Git.               |
| `klundstedt-mini`              | Source author/merge host for dotfiles and iv-image; fleet rollout coordinator. |
| Ephemeral exe.dev canary       | On-demand Linux validation with read-only repo integrations by default.        |

## Source migration

The installer must tolerate a fresh or previously configured local Git file:

```bash
git config --file ~/.gitconfig_local --unset-all commit.gpgsign || true
git config --file ~/.gitconfig_local --unset-all user.signingkey || true
```

On Macs, authenticate GitHub CLI and configure Git HTTPS integration:

```bash
gh auth login --hostname github.com --git-protocol https --web
gh auth setup-git --hostname github.com
```

Convert direct GitHub remotes to `https://github.com/OWNER/REPO.git`. Scoped
exe.dev integration remotes already use HTTPS and require no PAT on the VM.

## Canary procedure

1. Create an ephemeral exe.dev VM and attach the read-only dotfiles and
   iv-image integrations.
2. Pull the candidate commit, run `~/dotfiles/install.sh`, and verify
   `commit.gpgsign` and `user.signingkey` are unset.
3. Verify personal/work author identity still resolves from each repository
   remote URL.
4. If a push canary is explicitly required, temporarily attach the matching
   writer integration, push and delete a temporary branch, then detach the
   writer immediately afterward.
5. Delete the canary and its stale tailnet node after validation.
6. On the mini with 1Password locked, verify GitHub CLI HTTPS fetch and push for
   one personal and one IndustryVault repository. Verify `sync-repos.sh`.

## Fleet rollout and rollback

From `klundstedt-mini`, serially inspect every VM for dirty or unpushed work,
pull dotfiles, run `~/dotfiles/install.sh --skip-agents`, audit remotes, and
verify fetches. Test pushes only for writable project repositories. Record each
completion; do not recreate VMs or rebuild iv-image for this migration.

If a host fails, restore the prior dotfiles commit on that host and re-run the
installer. Do not reintroduce SSH rewrites as an ad-hoc workaround; diagnose
GitHub CLI credential or integration scope instead.

## Execution record — 2026-07-22

- `klundstedt-mini` authenticated GitHub CLI for HTTPS and pushed the migration
  commits over `https://github.com/kylelundstedt/dotfiles.git`.
- `kgl-dotfiles` passed the no-agent canary: `install.sh` cleared signing
  settings, personal and IndustryVault identity resolution passed, and an
  unsigned temporary branch pushed through
  `github-kylelundstedt-dotfiles-writer` before being deleted.
- Before retirement, `kgl-dotfiles` consumed iv-image through the read-only
  `github-kylelundstedt-iv-image` endpoint; fetch succeeded and dry-run push
  returned HTTP 403. The iv-image writer integration had no attachments.
- Completed serial rollout: `iv-ave-adapters`, `rss-feed`, `iv-gitlake`,
  `iv-gitlake-examples`, `iv-home`, `iv-docs`, and `kgl-thoughts`. Each has
  signing unset, fetched dotfiles over HTTPS, and completed a dry-run
  project-repository push through its scoped integration. `iv-home`'s untracked
  local `.claude/settings.local.json` and `iv-docs` staged project work were
  preserved. On `kgl-thoughts`, an install-generated personal-overlay block had
  dirtied the stowed source; it was discarded and only the Git/Zsh stow migration
  was applied to avoid re-running that unrelated overlay path.
- `klundstedt-mbp` completed the final validation interactively: signing is
  unset; personal dotfiles fetch and dry-run push succeeded with both
  `SSH_AUTH_SOCK` and `GITHUB_TOKEN` removed; and an IndustryVault repository
  (`industryvault-new`) dry-run push succeeded after GitHub CLI was authorized
  for the organization’s SAML SSO.
- After the fleet canary completed, `kgl-dotfiles` was moved back to read-only.
  Its AgentsView work was mirrored to the mini, its Shelley database and Git
  bundles were archived, all integrations were detached, and the VM was retired.
  Both dedicated writer integrations remain unattached and are available only
  for an explicit, temporary push canary.

## Completion criteria

- GitHub branch rules do not require signed commits.
- An ephemeral Linux canary and both Macs pass HTTPS fetch/push validation.
- Every VM is updated without dirty-worktree loss.
- Obsolete SSH-signing and GitHub-SSH documentation is removed.
- Dedicated VM writer integrations have no attachments by default.
- Old GitHub signing keys may be retired later; key deletion is not part of this
  migration.

## References

- [GitHub CLI authentication](https://cli.github.com/manual/gh_auth_login)
- [GitHub CLI Git credential setup](https://cli.github.com/manual/gh_auth_setup-git)
- [Git remote URL management](https://docs.github.com/en/get-started/git-basics/managing-remote-repositories)
- [exe.dev GitHub integrations](https://exe.dev/docs/integrations-github)

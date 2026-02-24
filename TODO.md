# TODO

## Devbox image (reproducible dev environment)
- [ ] Build `image/Dockerfile` with pinned tool versions, `klundstedt` user
- [ ] Build `image/build.sh` for local builds via `container build`
- [ ] Update `container.sh` to use devbox image instead of `ubuntu:25.04`
- [ ] Determine full tool list and versions (driven by GitLake needs)
- [ ] Test end-to-end: `zp --backend container` with devbox image
- [ ] Sprite: wait for checkpoint forking, then create golden sprite from devbox

## zp
- [x] Exclude `dotfiles` from project list (container + sprite backends)
- [x] Project-first design with non-interactive mode
- [x] Consistent `~/github/owner/name` paths across all backends
- [ ] Create `/zp` skill for agent-driven usage
- [ ] Add self-clone for curl one-liner bootstrap
- [ ] Add Spotlight/Shortcuts integration (osascript fallback when no tty)

## install.sh
- [x] Test on macOS (clean `~/.local/bin`) — verify GitHub release binary matching for arm64
- [x] Test on Linux — container (root) + sprite (non-root), 33/33 passing
- [x] Fix fnm arch on aarch64 Linux (`fnm-arm64.zip` not `fnm-linux.zip`)
- [x] Remove `just` from CLI tools and test verify list
- [x] Rename `test-linux.sh` → `test-install.sh`
- [ ] Test `--apps` flag (brew bundle casks + MAS apps)

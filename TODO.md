# TODO

## Devbox image (reproducible dev environment)
- [ ] Build `image/Dockerfile` with pinned tool versions, `klundstedt` user
- [ ] Build `image/build.sh` for local builds via `container build`
- [ ] Update `container.sh` to use devbox image instead of `ubuntu:25.04`
- [ ] Determine full tool list and versions (driven by GitLake needs)
- [ ] Test end-to-end: `zop --backend container` with devbox image
- [ ] Sprite: wait for checkpoint forking, then create golden sprite from devbox

## zop
- [ ] Add self-clone for curl one-liner bootstrap
- [ ] Add Spotlight/Shortcuts integration (osascript fallback when no tty)

## install.sh
- [x] Test on macOS (clean `~/.local/bin`) — verify GitHub release binary matching for arm64
- [ ] Test `--apps` flag (brew bundle casks + MAS apps)


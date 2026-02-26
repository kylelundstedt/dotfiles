# TODO

## Remote Dev

- [ ] Setup proxies from containers and sprites back to local
- [ ] https://docs.sprites.dev/cli/installation/#optional-local-directory-context

## Devbox image (reproducible dev environment)

- [ ] Build `image/Dockerfile` with pinned tool versions, `klundstedt` user
- [ ] Build `image/build.sh` for local builds via `container build`
- [ ] Update `container.sh` to use devbox image instead of `ubuntu:25.04`
- [ ] Determine full tool list and versions (driven by GitLake needs)
- [ ] Test end-to-end: `zp --backend container` with devbox image
- [ ] Sprite: wait for checkpoint forking, then create golden sprite from devbox

## zp

- [ ] Add self-clone for curl one-liner bootstrap
- [ ] Add Spotlight/Shortcuts integration (osascript fallback when no tty)

## install.sh

- [ ] Test `--apps` flag (brew bundle casks + MAS apps)
- [ ] Ensure timely and correct upgrades for Apple `container`

## 1Password

- [ ] Consider 1Password Connect with Tailscale

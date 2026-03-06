# TODO

## Remote Dev

- [ ] Setup proxies from containers and sprites back to local
- [ ] https://docs.sprites.dev/cli/installation/#optional-local-directory-context
- [x] How to update `containers` release safely on macos machines

## Devbox image (reproducible dev environment)

- [ ] Build `image/Dockerfile` with pinned tool versions, `klundstedt` user
- [ ] Build `image/build.sh` for local builds via `container build`; https://github.com/apple/container/pull/937
- [ ] Update `container.sh` to use devbox image instead of `ubuntu:25.04`
- [ ] Determine full tool list and versions (driven by GitLake needs)
- [ ] Test end-to-end: `zp --backend container` with devbox image
- [ ] Sprite: wait for checkpoint forking, then create golden sprite from devbox

## zp

- [ ] Add self-clone for curl one-liner bootstrap
- [ ] Add Spotlight/Shortcuts integration (osascript fallback when no tty)

## install.sh

- [ ] Test `--apps` flag (brew bundle casks + MAS apps)
- [x] Ensure timely and correct upgrades for Apple `container`

## Zed

- [ ] Re-add `CLAUDE_CODE_EXECUTABLE: "claude"` to `agent_servers.claude.env` once Zed ships ACP adapter with SDK >= 0.2.61 (fix: anthropics/claude-agent-sdk-typescript#205)

## 1Password

- [ ] Consider 1Password Connect with Tailscale

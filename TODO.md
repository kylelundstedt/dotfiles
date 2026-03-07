# TODO

## Devbox image (reproducible dev environment)

- [ ] Build `image/Dockerfile` with pinned tool versions, `klundstedt` user
- [ ] Build `image/build.sh` for local builds via `container build`
- [ ] Update `container.sh` to use devbox image instead of `ubuntu:25.04`
- [ ] Determine full tool list and versions (driven by GitLake needs)
- [ ] Test end-to-end with devbox image in Apple Container
- [ ] Sprite: wait for checkpoint forking, then create golden sprite from devbox

## Secrets

- [ ] Consider single-repo GitHub PATs -- https://exe.dev/docs/faq/github-token
- Current workaround: resolve secrets on Mac, pass as ephemeral env vars (like TS_AUTHKEY)

# TODO

## Fix install.sh + test-install.sh -- DONE

### Current status

| Backend   | Smoke test (create/access/destroy) | test-install.sh (full install + verify) |
| --------- | ---------------------------------- | --------------------------------------- |
| Container | PASS                               | 33/33 PASS                              |
| Sprite    | PASS                               | 33/33 PASS                              |
| exe.dev   | PASS                               | 33/33 PASS                              |

### Phase 0: Smoke-test VM access -- DONE

- [x] Apple Container: create, exec, destroy -- PASS
- [x] Sprite: create, exec, destroy -- PASS
- [x] exe.dev: PASS -- fixed by creating dedicated 1Password SSH key ("SSH Key - exe.dev"), registering with exe.dev, exporting public key to `~/.ssh/exe_dev.pub`, and adding `IdentitiesOnly yes` + `IdentityFile` to SSH config

### Phase 1: Fix install.sh -- DONE

- [x] No-systemd tailscaled: pgrep check, then systemctl, then `nohup tailscaled --tun=userspace-networking`
- [x] GITHUB_TOKEN: env var passthrough works; callers (test-install.sh) resolve from `gh auth token`

### Phase 2: Fix test-install.sh -- DONE

- [x] GITHUB_TOKEN: resolve from `gh auth token`, pass to all VMs
- [x] TS_AUTHKEY: fail loudly if empty instead of silent `|| true`
- [x] tar xattr warnings: `COPYFILE_DISABLE=1` on create, `--warning=no-unknown-keyword` on extract
- [x] exe.dev: use HTTPS API (`curl https://exe.dev/exec`) with bearer token for lobby commands instead of SSH
- [x] exe.dev: VM name can't end with `-<digits>` (exe.dev naming rule)
- [x] exe.dev: default user is root (no sudo), install sudo before creating klundstedt user
- [x] Sprite: `-env` flag only passes last value with multiple flags; use comma-separated format

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

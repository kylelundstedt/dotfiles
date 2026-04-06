# TODO

## Devbox image (reproducible dev environment)

### Build

- [ ] Determine full tool list and versions (driven by GitLake needs)
- [ ] Build `image/Dockerfile` with pinned tool versions, `klundstedt` user
- [ ] Build `image/build.sh` for local builds via `container build`

### Deploy per backend

- [ ] Apple Container: update `container` to use devbox image instead of `ubuntu:25.04`
- [ ] exe.dev: use devbox image via `new --image`
- [ ] Sprite: wait for checkpoint forking, then create golden sprite from devbox (no custom image support yet)

### Validate

- [ ] Test end-to-end on Apple Container
- [ ] Test end-to-end on exe.dev
- [ ] Test end-to-end on Sprite (once checkpoint forking lands)

## Secrets on remote VMs

- GitHub: SSH agent forwarding via Tailscale handles clone/push/signing — no tokens needed (implemented 2026-04-06)
- Tailscale: `TS_AUTHKEY` resolved on Mac via `op read`, passed as env var at VM creation
- [x] GitHub access on VMs — solved via SSH agent forwarding (ForwardAgent + CanonicalizeHostname)
- [x] Git commit signing on VMs — solved via .zshrc login-time hook (detects forwarded agent)
- [ ] Evaluate Tailscale OAuth clients for reusable, non-expiring auth keys
- [ ] Decide on 1Password strategy for VMs:
  - Mac-side resolution (current) — simple, works for test/ephemeral VMs
  - Service Accounts — one `OP_SERVICE_ACCOUNT_TOKEN` env var, needs `op` on each VM
  - Connect Server on tailnet — one persistent VM runs Docker containers, other VMs query via HTTP + `OP_CONNECT_TOKEN`. No `op` needed on clients. Worth it when VMs need autonomous secret access (long-lived devboxes, unattended agents).

## Apple Containers

- [ ] `container create` broken in 0.11.0 — rootfs never provisioned (apple/container#1398). Workaround: `container run -d`. Skill already uses the workaround.

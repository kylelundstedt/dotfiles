# exe.dev multi-tenant plan (future — gated on first paying client)

Decision record and build-out plan for serving multiple clients from this
setup. Nothing here is active work; the trigger is the first paying client.

## Decisions

- **2026-05-23** — single tailnet for now (Option 1: you create VMs,
  contractors use them via `*.exe.xyz`). Move to per-tenant tailnets
  (Option 2) when there's a paying client.
- **2026-05-30** — when Option 2 lands, pair each per-client tailnet with a
  **per-client exe.dev account** and the "switch-the-Mac" operational pattern
  (`tailscale switch` between client tailnets). Tag stays `tag:dev` within
  each tailnet — isolation is at the account+tailnet boundary, not the tag.
  Full analysis: `gitlake:iv/reference/exe_dev_multi_tenant.md`.
- **2026-07-13** (`repo-boundaries.md`) — when the first client lands, the
  repo split to make is personal-vs-client, not further slicing of this repo.
- **2026-07-22** (`secrets.md` → "Choosing where a secret lives") — the
  four-tier secret-placement rule extends to clients by scope substitution:
  per-**client** vault + per-client read-only 1Password service account
  wherever tier 3 is unavoidable, exactly as per-project works today. The
  tiering matters more under multi-tenancy, not less: a tier-3 SA token on a
  VM yields everything in the vault it can read, so the vault boundary _is_
  the client isolation boundary for any secret an exe.dev integration cannot
  carry. Prefer tiers 1–2 for client work whenever the target is a public
  HTTPS host.

## Build-out checklist (in order)

1. Factor `install.sh setup_git`'s SSH-config generation into a standalone
   `regen-ssh-config` script invoked by `ts-switch`
2. `ts-switch <clientid>` zsh function in `zsh/.zshrc`:
   `tailscale switch iv-<clientid> && regen-ssh-config`
3. `install.sh setup_tailscale` (macOS): support multiple `tailscale up`
   profiles, one per client tailnet
4. `install.sh setup_git`: emit per-account `Host exe-<clientid>.dev` blocks
   (per-account `IdentityFile`) from a `clients.conf` at repo root
5. `test-install.sh test_no_hook`: iterate over accounts from `clients.conf`
6. `bin/add-client <clientid>` helper: one-shot create of tailnet OAuth
   client + `tailscale-api` integration + 1Password entries +
   `clients.conf` row
7. Per-tenant plumbing from the earlier notes: per-client tailnet + OAuth
   client + `tailscale-api-<client>` integration; team integrations
   (`--team`) for client-scoped MCP servers

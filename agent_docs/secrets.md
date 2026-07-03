# Secret Management

Secrets are never stored in plaintext. Each secret uses the narrowest delivery mechanism available.

## exe.dev VMs

No credentials on VM disk. Integrations are scoped by tag (client/project) or per-VM:

| Integration           | Type       | Scope        | Purpose                                                      |
| --------------------- | ---------- | ------------ | ------------------------------------------------------------ |
| `tailscale-api`       | http-proxy | `auto:all`   | Setup script generates ephemeral Tailscale auth keys at boot |
| `github-mcp-work`     | http-proxy | `tag:iv`     | Work GitHub API (MCP)                                        |
| `motherduck-mcp`      | http-proxy | `tag:iv`     | MotherDuck SQL (MCP)                                         |
| `github-mcp-home`     | http-proxy | `vm:` per VM | Personal GitHub API (MCP) — only your VMs                    |
| `github-<org>-<repo>` | github     | `vm:` per VM | Git clone/push for a single repo                             |
| `reflection`          | reflection | `auto:all`   | VM metadata                                                  |
| tigris                | OAuth      | —            | One-time browser dance via `LocalForward 8765`               |
| readwise              | OAuth      | —            | macOS only                                                   |

**Tag convention:** VMs are tagged by client (e.g. `iv`, `usaa`). Tag-scoped integrations grant access to the appropriate set of services. When team members join via SSO, personal integrations remain invisible to them; team integrations (`--team` flag) only support `tag:` attachment.

Commit signing uses SSH agent forwarding over Tailscale (`ForwardAgent yes` for `*.ts.net`). The private key stays in 1Password on the Mac.

## MCP Servers

MCP servers use remote HTTP transport. No local wrapper scripts or `.env` files.

**On macOS** — OAuth for MotherDuck/Tigris/Readwise (browser auth on first use). GitHub servers use PATs from 1Password, resolved at install time via `op read`.

## 1Password Patterns

Read a single secret:

```bash
op read "op://Employee/SomeService/api_key" --account industryvault.1password.com
```

Inject secrets into a command via env file:

```bash
# .env (secret references, not values)
DATABASE_URL=op://Employee/ProjectDB/connection_string
API_KEY=op://Employee/SomeService/api_key

op run --env-file=.env -- your-command
```

## Platform Notes

- **macOS** — 1Password desktop app handles auth (biometric on first access)
- **Linux VMs** — 1Password CLI not configured; secrets come from exe.dev integrations or are passed as ephemeral env vars from the Mac

## Credential Inventory & Rotation Runbook

Machine-readable expiry dates live in `provisioning/keys.manifest`, checked monthly by `provisioning/check-key-expiry.sh` (launchd `com.kylelundstedt.check-key-expiry`, 1st of the month, 35-day warning window — wider than the monthly cadence so nothing slips between runs). Optional dead-man's-switch ping URL in the login Keychain under `key-expiry:healthcheck-url`. **Update the manifest's `expires` column on every rotation.**

| Credential                            | 1Password item (account)                                                | Expires        | Fan-out (rotation must touch all)                                                                            |
| ------------------------------------- | ----------------------------------------------------------------------- | -------------- | ------------------------------------------------------------------------------------------------------------ |
| Tailscale API key                     | not in 1P — lives only in the exe.dev `tailscale-api` integration       | **2026-08-21** | exe.dev `tailscale-api` http-proxy integration (used by `join-tailnet` at VM boot)                           |
| Tailscale auth key `iv-internal-dev`  | `op://Employee/Tailscale - iv-internal-dev/credential` (industryvault)  | unknown        | `install.sh setup_tailscale` (macOS `tailscale up`), apple-containers + sprites-dev skills                   |
| Tailscale auth key `iv-internal-test` | `op://Employee/Tailscale - iv-internal-test/credential` (industryvault) | unknown        | `test-install.sh` (TS_AUTHKEY)                                                                               |
| GitHub PAT Home                       | `op://Private/GitHub PAT Home/token` (lundstedts)                       | unknown        | `claude mcp` github-home (macOS), gh auth headless fallback, exe.dev `github-mcp-home` integration           |
| GitHub PAT IV                         | `op://Employee/GitHub PAT IV/token` (industryvault)                     | unknown        | `claude mcp` github-work (macOS), Keychain `sync-repos:IndustryVault`, exe.dev `github-mcp-work` integration |
| GitHub PAT IV-CMG                     | `op://Employee/GitHub PAT IV-CMG/token` (industryvault)                 | unknown        | Keychain `sync-repos:iv-cmg`                                                                                 |
| Tigris backup rclone key              | `op://Personal/Tigris mini-backup rclone key` (industryvault)           | none           | Keychain `tigris-backup:s3-key-id` / `s3-secret` (mini)                                                      |
| Tigris backup crypt password+salt     | `op://Personal/Tigris mini-backup rclone crypt` (industryvault)         | none           | Keychain `tigris-backup:crypt-password` / `crypt-salt` (mini) — **DR-critical: never rotate without a plan** |
| OWC8TB disk passphrase                | `op://Personal/OWC8TB disk encryption/password` (industryvault)         | none           | Keychain `owc8tb-encryption` (mini)                                                                          |

### Rotation procedures

**Tailscale API key** (deadline 2026-08-21 — or retire it entirely by migrating the integration to a Tailscale OAuth client, see the simplification plan, decision 4):

1. Tailscale admin console → Settings → Keys → generate a new API access token.
2. `ssh exe.dev integrations remove tailscale-api`, then re-add the http-proxy integration with the new token (verify the exact `integrations add` flags via `ssh exe.dev help` — not documented locally).
3. Verify: run the `join-tailnet` flow on a throwaway VM (or `./test-install.sh exe`).

**Tailscale auth keys** (`iv-internal-dev` / `iv-internal-test`): regenerate in the admin console (reusable, `tag:dev`), update the 1P item — consumers read 1P at run time, so no other fan-out.

**GitHub PATs** (fine-grained, per resource owner): regenerate on github.com → update the 1P item → re-run `./install.sh` (re-resolves MCP registrations and re-provisions the sync-repos/tigris-backup Keychain items) → for Home/IV also `ssh exe.dev integrations remove github-mcp-home` (resp. `github-mcp-work`) and re-add with the new token. Record the new expiry in `provisioning/keys.manifest`.

**Tigris/OWC8TB secrets**: static, no expiry. If ever rotated: update 1P, re-run `./install.sh` on the mini, and for the crypt password/salt re-encrypt or start a new backup generation first — the old archive is unreadable without the old values.

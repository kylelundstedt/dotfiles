# Secret Management

Secrets are never stored in plaintext. Each secret uses the narrowest delivery mechanism available.

## exe.dev VMs

No credentials on VM disk. Integrations are scoped by tag (client/project) or per-VM:

| Integration           | Type       | Scope        | Purpose                                                     |
| --------------------- | ---------- | ------------ | ----------------------------------------------------------- |
| `tailscale-api`       | http-proxy | `auto:all`   | OAuth client creds (Basic) → 1h token → ephemeral join keys |
| `github-mcp-work`     | http-proxy | `tag:iv`     | Work GitHub API (MCP)                                       |
| `motherduck-mcp`      | http-proxy | `tag:iv`     | MotherDuck SQL (MCP)                                        |
| `github-mcp-home`     | http-proxy | `vm:` per VM | Personal GitHub API (MCP) — only your VMs                   |
| `github-<org>-<repo>` | github     | `vm:` per VM | Git clone/push for a single repo                            |
| `reflection`          | reflection | `auto:all`   | VM metadata                                                 |
| tigris                | OAuth      | —            | One-time browser dance via `LocalForward 8765`              |
| readwise              | OAuth      | —            | macOS only                                                  |

**Tag convention:** VMs are tagged by client (e.g. `iv`, `usaa`). Tag-scoped integrations grant access to the appropriate set of services. When team members join via SSO, personal integrations remain invisible to them; team integrations (`--team` flag) only support `tag:` attachment.

Git operations use HTTPS. Macs authenticate through GitHub CLI credentials in the system credential store; exe.dev VMs use scoped GitHub integrations. No Git PAT or commit-signing key is stored on a VM.

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

| Credential                           | 1Password item (account)                                        | Expires | Fan-out (rotation must touch all)                                                                            |
| ------------------------------------ | --------------------------------------------------------------- | ------- | ------------------------------------------------------------------------------------------------------------ |
| Tailscale OAuth client               | `op://Employee/Tailscale OAuth Dev` (industryvault)             | none    | exe.dev `tailscale-api` integration (Basic header), install.sh (mini + VM joins), test-install.sh, skills    |
| GitHub PAT Home                      | `op://Private/GitHub PAT Home/token` (lundstedts)               | unknown | `claude mcp` github-home (macOS), gh auth headless fallback, exe.dev `github-mcp-home` integration           |
| GitHub PAT IV                        | `op://Employee/GitHub PAT IV/token` (industryvault)             | unknown | `claude mcp` github-work (macOS), Keychain `sync-repos:IndustryVault`, exe.dev `github-mcp-work` integration |
| GitHub PAT IV-CMG                    | `op://Employee/GitHub PAT IV-CMG/token` (industryvault)         | unknown | Keychain `sync-repos:iv-cmg`                                                                                 |
| Tigris backup rclone key             | `op://Personal/Tigris mini-backup rclone key` (industryvault)   | none    | Keychain rclone key + daily/reconcile Healthchecks URLs (mini; see backup runbook)                           |
| Tigris backup crypt password+salt    | `op://Personal/Tigris mini-backup rclone crypt` (industryvault) | none    | Keychain `tigris-backup:crypt-password` / `crypt-salt` (mini) — **DR-critical: never rotate without a plan** |
| OWC8TB disk passphrase               | `op://Personal/OWC8TB disk encryption/password` (industryvault) | none    | Keychain `owc8tb-encryption` (mini)                                                                          |
| healthchecks.io API key (read-write) | not in 1P — Keychain only                                       | none    | Keychain `healthchecks:api-key` (mini) — manages check configs (see `monitoring.md`)                         |

### Rotation procedures

**Tailscale OAuth client** (U11, 2026-07 — replaced the expiring API key AND the static `iv-internal-*` auth keys; nothing expires anymore): scopes `Auth Keys: Write` + `Devices Core: Write`, tag `tag:dev`. The raw client secret is NOT accepted as a static Bearer/Basic API credential — consumers do the standard OAuth exchange (`POST /api/v2/oauth/token`, `client_secret_basic`) for a 1h token. The exe.dev integration injects `Authorization: Basic base64(client_id:client_secret)`, so VM flows exchange THROUGH the proxy and then hit the public API with the token. If the client is ever compromised/rotated:

1. Admin console → Settings → OAuth clients → regenerate the secret (scopes/tags are editable in place).
2. Update both fields in 1P `Tailscale OAuth Dev`, then swap the integration:
   `ssh exe.dev integrations remove tailscale-api` and
   `ssh exe.dev integrations add http-proxy --name=tailscale-api --target=https://api.tailscale.com --header='Authorization:Basic <base64(client_id:client_secret)>' --attach=auto:all`
3. Verify: `join-tailnet` on a throwaway VM.

**GitHub PATs** (fine-grained, per resource owner): regenerate on github.com → update the 1P item → re-run `./install.sh` (re-resolves MCP registrations and re-provisions the sync-repos/tigris-backup Keychain items) → for Home/IV also `ssh exe.dev integrations remove github-mcp-home` (resp. `github-mcp-work`) and re-add with the new token. Record the new expiry in `provisioning/keys.manifest`.

**Tigris/OWC8TB secrets**: static, no expiry. If ever rotated: update 1P, re-run `./install.sh` on the mini, and for the crypt password/salt re-encrypt or start a new backup generation first — the old archive is unreadable without the old values.

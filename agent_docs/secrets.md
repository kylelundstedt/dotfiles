# Secret Management

Secrets are never committed. Prefer integrations or 1Password/Keychain; when a
service requires a local secret file, keep it narrowly scoped and mode `0600`.

## Choosing where a secret lives

Work down this list and stop at the first tier that fits. The ordering is by
what an attacker gets from a compromised VM, not by convenience.

| Tier | Mechanism                                  | Secret on VM?           | What a compromised VM yields                                                      |
| ---- | ------------------------------------------ | ----------------------- | --------------------------------------------------------------------------------- |
| 1    | Typed exe.dev integration (`github`, `s3`) | No                      | Ability to _use_ the credential, scoped by the integration; nothing to exfiltrate |
| 2    | Generic exe.dev `http-proxy` integration   | No                      | Same — the header is injected server-side at egress                               |
| 3    | 1Password service account + `op run`       | Yes — the SA token      | Everything in the vault that SA can read                                          |
| 4    | Plaintext secret in an env file            | Yes — the secret itself | The secret, directly                                                              |

**Decision rule.** Ask, in order:

1. Is there a **typed** integration for this service (`github`, `s3`)? Use it —
   it carries semantics you'd otherwise hand-roll (`--readonly`, per-repo
   scoping).
2. Can the tool be pointed at a **custom base URL**, and is its backend a
   **public HTTPS host**? Use a generic `http-proxy` integration. This covers
   far more than it appears: `tailscale-api`, `motherduck-api`, and both
   `github-mcp-*` entries below are all the same `http-proxy` type with
   different targets and headers — there is no per-vendor integration type
   involved.
3. Otherwise — the tool needs a **literal secret value** in its environment or
   config, speaks something other than HTTPS, can't take a custom base URL, or
   the target isn't a public hostname — use a **1Password service account**
   with `op run --env-file` (tier 3).
4. Never tier 4 for anything new.

**Why the target can't be private (tier 2's real limit).** exe.dev's proxy
egresses from exe.dev's infrastructure, not from the VM, and it rejects targets
it could never reach — verified 2026-07-22:

```
--target=https://<host>.ts.net  → "target URL must not use a .ts.net domain"
--target=https://100.127.121.69 → "target URL must use a hostname, not an IP address"
```

So anything on the tailnet is out of reach of tier 2 by construction, and drops
to tier 3.

**What tier 3 costs, stated plainly.** It does not keep secrets off the VM — it
swaps an application secret for an `OP_SERVICE_ACCOUNT_TOKEN` in a `0600`
`EnvironmentFile`. The gains are real but specific: the SA token is centrally
revocable, scoped to one vault, grants no direct access to the underlying
service, and rotating the underlying secret becomes a 1Password edit plus a
service restart rather than a per-VM file edit. **This is why vault-per-project
matters** — the token's blast radius is exactly one vault, so scope one vault
and one read-only SA per project. Do not store an SA's own credential item in
the vault that SA can read.

Mechanism verified 2026-07-22 (gates, gotchas, and the fails-closed behavior):
[shelley-dual-provider.md](shelley-dual-provider.md) → "1Password
service-account delivery". For client-scoped extensions of this tiering, see
[multi-tenant.md](multi-tenant.md).

## exe.dev VMs

No _application_ credentials on VM disk — integrations inject them server-side.
The sole exception is a tier-3 bootstrap credential (an `OP_SERVICE_ACCOUNT_TOKEN`
scoped to one project vault), used only where no integration can reach the
target. Integrations are scoped by tag (client/project) or per-VM:

| Integration           | Type       | Scope                        | Purpose                                                                                                                                                                                                                                                                                     |
| --------------------- | ---------- | ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `tailscale-api`       | http-proxy | **`(none)`**                 | OAuth client creds (Basic) → 1h token → ephemeral join keys. Attached on demand by `join-tailnet`, detached on exit — see below                                                                                                                                                             |
| `github-mcp-work`     | http-proxy | **`(none)`**                 | Work GitHub API (MCP). No VM has an IndustryVault/iv-cmg repo, so none needs it; attach per-VM if that changes                                                                                                                                                                              |
| `motherduck-mcp`      | http-proxy | `tag:iv`                     | MotherDuck SQL (MCP) — the sanctioned one (`mcp.manifest`)                                                                                                                                                                                                                                  |
| `motherduck-api`      | http-proxy | **`(none)`**                 | Same target/auth as `motherduck-mcp`, no config consumer, in no manifest. Detached 2026-07-28; `tag:motherduck-api` kept as the restore path                                                                                                                                                |
| `github-mcp-home`     | http-proxy | `tag:iv` + `vm:kgl-thoughts` | Personal GitHub API (MCP) — every VM where agents do GitHub work, minus the two public ones                                                                                                                                                                                                 |
| `llm`                 | llm        | `auto:all`                   | Keyless LLM gateway. Deliberate global default; the redundant `tag:llm` attachment was dropped                                                                                                                                                                                              |
| `telnyx-test`         | catalog    | `vm:telnyx-vm`               | Telnyx API (Bearer) for the number port + voicemail/SMS. `vm:iv-home` was a stray, detached 2026-07-28                                                                                                                                                                                      |
| `fannie-token`        | http-proxy | `vm:iv-foundry-stage2`       | Fannie SSO — **keep attached**: it is how M3 downloads fannie-sflpd data. `tag:fannie-token` was dead (no VM carried it) and was detached; the `vm:` attach is the live one. Currently returns 403 from Fannie's own SSO, i.e. not working upstream yet — that is not an attachment problem |
| `github-<org>-<repo>` | github     | `vm:` per VM                 | Git clone/push for a single repo                                                                                                                                                                                                                                                            |
| `reflection`          | reflection | `auto:all`                   | VM metadata                                                                                                                                                                                                                                                                                 |
| tigris                | OAuth      | —                            | One-time browser dance via `LocalForward 8765`                                                                                                                                                                                                                                              |
| readwise              | OAuth      | —                            | macOS only                                                                                                                                                                                                                                                                                  |

**Attachment drift is real, and this table is intent — verify against
`ssh exe.dev integrations list` before trusting it.** As of 2026-07-28 both
`github-mcp-*` entries were live at `auto:all` rather than the narrower scopes
recorded above; nobody widened them deliberately. Two related traps:

- An `auto:all` integration lands on **every new VM automatically**, so a
  replacement VM inherits it on first boot.
- A `tag:` attachment whose tag no VM carries still appears in
  `integrations list` and grants nothing — `fannie-token` had exactly this dead
  `tag:fannie-token` attachment. Prefer `vm:` for singleton or high-risk
  authority; reserve tags for genuine cohorts.

**To check whether a VM has an integration, use the reflection endpoint, not an
HTTP status code.** `curl https://<name>.int.exe.xyz/` returning 403 is
ambiguous: exe.dev returns 403 when the integration is _not attached_, and the
upstream service can also return 403 through a perfectly good proxy.
`fannie-token` on `iv-foundry-stage2` is attached and returns 403 because
Fannie's SSO rejects it — an upstream problem, not an attachment one. The
authoritative VM-side view is:

```bash
curl -s https://reflection.int.exe.xyz/integrations | jq -r '..|objects|select(has("name"))|.name'
```

Cross-check it against `ssh exe.dev integrations list` (the control-plane view);
the two agreeing is the real verification.

See [`exe-dev-remediation.md`](exe-dev-remediation.md) for the audit.

**Tag convention:** VMs are tagged by client (e.g. `iv`, `usaa`). Tag-scoped integrations grant access to the appropriate set of services. When team members join via SSO, personal integrations remain invisible to them; team integrations (`--team` flag) only support `tag:` attachment.

Git operations use HTTPS. Macs authenticate through GitHub CLI credentials in the system credential store; exe.dev VMs use scoped GitHub integrations. No Git PAT or commit-signing key is stored on a VM.

## MCP Servers

MCP servers use remote HTTP transport. No local wrapper scripts or `.env` files.

**On macOS** — OAuth for MotherDuck/Tigris/Readwise (browser auth on first use). GitHub servers use PATs from 1Password, resolved at install time via `op read`.

## AgentsView pilot tokens

AgentsView HTTP remote sync requires a distinct bearer token per source host.
During the 2026-07-22 canary bootstrap:

- each Linux canary stores only its own token in
  `~/.config/agentsview/source.env` (mode `0600`);
- the mini collector stores the two remote tokens and its UI/API token in
  `~/.agentsview/config.toml` (directory `0700`, file `0600`);
- the live mini data directory is excluded from generic backup, so tokens and
  raw mirrors are not copied to Tigris; only the staged SQLite snapshot is;
- no token is committed or shared fleet-wide.

Token authority moved to 1Password on 2026-07-22: `op://Personal/AgentsView
fleet tokens` (industryvault), a Secure Note with one concealed field per
consumer — `collector` for the mini's UI/API `auth_token`, then one field named
for each source host (`iv-docs`, `iv-sandbox`, …). Add a field per host as
Phase 2 rolls out; the local files are regenerated from those refs, never the
reverse.

The collector field is mirrored to login Keychain service
`agentsview:auth-token`. `agentsview-service` reads that first and falls back to
`config.toml` only if it is absent, so the Keychain copy is now the live path.
The earlier bootstrap failure was a remote-SSH Keychain permissions error;
writing it from an Aqua GUI session works.

Rotate one source independently by replacing its 1Password field, then its
`source.env` token and the matching collector `[[remote_hosts]].token`, then
restarting that source and the collector. Revoke all tokens by deleting those
local files/fields and stopping the services.

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
- **Linux VMs** — `install.sh` installs the 1Password CLI (`op`), but no account is signed in and none is needed: `op` authenticates non-interactively from `OP_SERVICE_ACCOUNT_TOKEN` alone (no desktop-app integration, unlike macOS). Secrets otherwise come from exe.dev integrations. Note service accounts require an explicit `--vault` on `op item get`, so scripts written against a signed-in `op` will break

## Credential Inventory & Rotation Runbook

Machine-readable expiry dates live in `provisioning/keys.manifest`, checked monthly by `provisioning/check-key-expiry.sh` (launchd `com.kylelundstedt.check-key-expiry`, 1st of the month, 35-day warning window — wider than the monthly cadence so nothing slips between runs). Optional dead-man's-switch ping URL in the login Keychain under `key-expiry:healthcheck-url`. **Update the manifest's `expires` column on every rotation.**

| Credential                           | 1Password item (account)                                        | Expires | Fan-out (rotation must touch all)                                                                                            |
| ------------------------------------ | --------------------------------------------------------------- | ------- | ---------------------------------------------------------------------------------------------------------------------------- |
| Tailscale OAuth client               | `op://Employee/Tailscale OAuth Dev` (industryvault)             | none    | exe.dev `tailscale-api` integration (Basic header), install.sh (mini + VM joins), test-install.sh, skills                    |
| GitHub PAT Home                      | `op://Private/GitHub PAT Home/token` (lundstedts)               | unknown | `claude mcp` github-home (macOS), gh auth headless fallback, exe.dev `github-mcp-home` integration                           |
| GitHub PAT IV                        | `op://Employee/GitHub PAT IV/token` (industryvault)             | unknown | `claude mcp` github-work (macOS), Keychain `sync-repos:IndustryVault`, exe.dev `github-mcp-work` integration                 |
| GitHub PAT IV-CMG                    | `op://Employee/GitHub PAT IV-CMG/token` (industryvault)         | unknown | Keychain `sync-repos:iv-cmg`                                                                                                 |
| Tigris backup rclone key             | `op://Personal/Tigris mini-backup rclone key` (industryvault)   | none    | Keychain rclone key + daily/reconcile Healthchecks URLs (mini; see backup runbook)                                           |
| Tigris backup crypt password+salt    | `op://Personal/Tigris mini-backup rclone crypt` (industryvault) | none    | Keychain `tigris-backup:crypt-password` / `crypt-salt` (mini) — **DR-critical: never rotate without a plan**                 |
| OWC8TB disk passphrase               | `op://Personal/OWC8TB disk encryption/password` (industryvault) | none    | Keychain `owc8tb-encryption` (mini)                                                                                          |
| AgentsView fleet bearer tokens       | `op://Personal/AgentsView fleet tokens` (industryvault)         | none    | mini `~/.agentsview/config.toml`; Keychain `agentsview:auth-token` (collector); per-source `~/.config/agentsview/source.env` |
| healthchecks.io API key (read-write) | not in 1P — Keychain only                                       | none    | Keychain `healthchecks:api-key` (mini) — manages check configs (see `monitoring.md`)                                         |

### Rotation procedures

**Tailscale OAuth client** (U11, 2026-07 — replaced the expiring API key AND the static `iv-internal-*` auth keys; nothing expires anymore): scopes `Auth Keys: Write` + `Devices Core: Write`, tag `tag:dev`. The raw client secret is NOT accepted as a static Bearer/Basic API credential — consumers do the standard OAuth exchange (`POST /api/v2/oauth/token`, `client_secret_basic`) for a 1h token. The exe.dev integration injects `Authorization: Basic base64(client_id:client_secret)`, so VM flows exchange THROUGH the proxy and then hit the public API with the token. If the client is ever compromised/rotated:

1. Admin console → Settings → OAuth clients → regenerate the secret (scopes/tags are editable in place).
2. Update both fields in 1P `Tailscale OAuth Dev`, then swap the integration:
   `ssh exe.dev integrations remove tailscale-api` and
   `ssh exe.dev integrations add http-proxy --name=tailscale-api --target=https://api.tailscale.com --header='Authorization:Basic <base64(client_id:client_secret)>'`
   — **do NOT re-add with `--attach=auto:all`.** This is tailnet administration
   (mint auth keys, remove nodes, edit ACLs); it was `auto:all` until
   2026-07-28, which put it on every VM including the public-facing ones.
   Leave it unattached; `join-tailnet` attaches and detaches per join.
3. Verify: `join-tailnet` on a throwaway VM.

**GitHub PATs** (fine-grained, per resource owner): regenerate on github.com → update the 1P item → re-run `./install.sh` (re-resolves MCP registrations and re-provisions the sync-repos/tigris-backup Keychain items) → for Home/IV also `ssh exe.dev integrations remove github-mcp-home` (resp. `github-mcp-work`) and re-add with the new token. Record the new expiry in `provisioning/keys.manifest`.

**Tigris/OWC8TB secrets**: static, no expiry. If ever rotated: update 1P, re-run `./install.sh` on the mini, and for the crypt password/salt re-encrypt or start a new backup generation first — the old archive is unreadable without the old values.

## Accepted risks

**telnyx-vm AgentsView bearer token — exposed 2026-07-29, NOT rotated.** An
agent printed `~/.agentsview/config.toml` with `tail` while testing the
collector-edit logic, putting one host's token into a session transcript.
Decision: accept. The token only authorises reading agent-session data from
that VM's source daemon on :8080, which binds the tailnet IP — using it already
requires tailnet access, which implies broader compromise. Rotating would mean
touching telnyx-vm mid-port for no meaningful reduction in risk.

If it is ever rotated: new token into `~/.config/agentsview/source.env` (0600)
on the VM, restart `agentsview-source.service` (a **user** unit — not the
telephony webhook on :8000), update the matching `[[remote_hosts]]` token in
`~/.agentsview/config.toml` on the mini, then kickstart the collector.

**Operational note for agents:** never `cat`/`tail`/`head` a file known to hold
credentials — `~/.agentsview/config.toml` and `~/.config/agentsview/source.env`
both do. Query for the field you need (`awk`/`grep` printing only the key), or
diff structurally. Two separate leaks in one session came from printing a body
"just to check the format".

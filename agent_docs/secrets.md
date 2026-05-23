# Secret Management

Secrets are never stored in plaintext. Each secret uses the narrowest delivery mechanism available.

## exe.dev VMs

No credentials on VM disk. Integrations are scoped by tag (client/project) or per-VM:

| Integration | Type | Scope | Purpose |
|---|---|---|---|
| `tailscale-api` | http-proxy | `auto:all` | Setup script generates ephemeral Tailscale auth keys at boot |
| `github-mcp-work` | http-proxy | `tag:iv` | Work GitHub API (MCP) |
| `motherduck-mcp` | http-proxy | `tag:iv` | MotherDuck SQL (MCP) |
| `github-mcp-home` | http-proxy | `vm:` per VM | Personal GitHub API (MCP) — only your VMs |
| `github-<org>-<repo>` | github | `vm:` per VM | Git clone/push for a single repo |
| `reflection` | reflection | `auto:all` | VM metadata |
| tigris | OAuth | — | One-time browser dance via `LocalForward 8765` |
| readwise | OAuth | — | macOS only |

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

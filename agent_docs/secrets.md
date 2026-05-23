# Secret Management

Secrets are never stored in plaintext. Each secret uses the narrowest delivery mechanism available.

## exe.dev VMs

exe.dev integrations handle the two secrets that every VM needs — no tokens on VM disk:

- **GitHub clone/push** — exe.dev GitHub integration. URLs like `https://<label>.int.exe.xyz/<org>/<repo>.git`. Attached per-VM (`integrations attach <label> vm:<vm>`) or globally (`auto:all`).
- **Tailscale auth** — `tailscale-api` HTTP proxy integration. The setup script (`exe-setup.sh`) generates a single-use ephemeral key via `POST /api/v2/tailnet/-/keys` through the proxy; exe.dev injects the bearer token.

Commit signing uses SSH agent forwarding over Tailscale (`ForwardAgent yes` for `*.ts.net` in SSH config). The private key stays in 1Password on the Mac.

## MCP Servers

MCP servers use remote HTTP transport. No local wrapper scripts or `.env` files.

**On exe.dev VMs** — three of five servers connect automatically via HTTP proxy integrations (no secrets on VM):

| Server | Integration | Auth |
|---|---|---|
| motherduck | `motherduck-mcp` | Static bearer token (auto) |
| github-home | `github-mcp-home` | Static bearer token (auto) |
| github-work | `github-mcp-work` | Static bearer token (auto) |
| tigris | — | OAuth (one-time browser dance via `LocalForward 8765`) |
| readwise | — | OAuth (one-time browser dance via `LocalForward 8765`) |

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

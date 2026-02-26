# Secret Management with 1Password

Secrets are never stored in plaintext. 1Password CLI (`op`) resolves secrets at runtime or install time.

## MCP Servers

MCP servers use remote HTTP transport. No local wrapper scripts or `.env` files needed.

**OAuth servers** (MotherDuck, Tigris) — no 1Password involvement. Authentication happens via browser OAuth flow on first use. Works on all environments.

**GitHub servers** (github-home, github-work) — PATs resolved from 1Password at install time via `op read` and stored in `~/.claude.json` as HTTP `Authorization` headers. Re-running `install.sh` refreshes them. Only registered on macOS where 1Password is configured.

```bash
# How install.sh resolves GitHub PATs
pat=$(op read "op://Private/GitHub PAT Home/token" --account lundstedts.1password.com)
claude mcp add-json --scope user github-home \
    "{\"type\":\"http\",\"url\":\"https://api.githubcopilot.com/mcp/\",\"headers\":{\"Authorization\":\"Bearer $pat\"}}"
```

## Using 1Password in Your Own Projects

Create a `.env` file with secret references in your project root:

```
DATABASE_URL=op://Employee/ProjectDB/connection_string
API_KEY=op://Employee/SomeService/api_key
```

Then run any command with those secrets injected:

```bash
op run --env-file=.env -- your-command
```

Or read a single secret value:

```bash
op read "op://Employee/SomeService/api_key"
```

## Platform Notes

- **macOS** with 1Password desktop app: auth persists while the app is unlocked (biometric prompt on first access)
- **Linux** without the desktop app: run `eval $(op signin --account <account>)` before starting Claude Code — the session token is inherited by child processes and lasts 30 minutes

## Troubleshooting

### 1Password CLI Not Working

Verify permissions: `chmod 700 ~/.config/op` and ensure 1Password desktop app is running

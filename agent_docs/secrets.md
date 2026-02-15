# Secret Management with 1Password

Secrets are never stored in plaintext. Instead, `.env` files contain [1Password secret references](https://developer.1password.com/docs/cli/secret-references) (`op://` URIs) that are resolved at runtime by `op run`. These `.env` files are safe to commit — they're just pointers, not secrets.

## How MCP Server Wrappers Work

Each MCP server has a wrapper script and a companion `.env` file in `agents/.agents/mcp/bin/`:

```
agents/.agents/mcp/bin/
├── github-mcp-home          # wrapper script
├── github-mcp-home.env      # secret references (committed to git)
├── motherduck-mcp
├── motherduck-mcp.env
└── ...
```

The `.env` file contains references like:

```
GITHUB_PERSONAL_ACCESS_TOKEN=op://Private/GitHub PAT Home/token
```

The wrapper resolves them with a single `op run` call:

```bash
exec op run --env-file="$SCRIPT_DIR/github-mcp-home.env" --no-masking \
    --account lundstedts.1password.com -- npx -y @modelcontextprotocol/server-github "$@"
```

## Using This Pattern in Your Own Projects

Create a `.env` file with secret references in your project root:

```
DATABASE_URL=op://Employee/ProjectDB/connection_string
API_KEY=op://Employee/SomeService/api_key
```

Then run any command with those secrets injected:

```bash
op run --env-file=.env -- your-command
```

## Platform Notes

- **macOS** with 1Password desktop app: auth persists while the app is unlocked (biometric prompt on first access)
- **Linux** without the desktop app: run `eval $(op signin --account <account>)` before starting Claude Code — the session token is inherited by child processes and lasts 30 minutes

## Troubleshooting

### 1Password CLI Not Working

Verify permissions: `chmod 700 ~/.config/op` and ensure 1Password desktop app is running

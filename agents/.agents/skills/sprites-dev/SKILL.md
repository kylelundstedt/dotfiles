---
name: sprites-dev
description: Use this skill when the user wants to manage remote Sprites from their local machine — listing sprites, executing commands, managing checkpoints, transferring files, controlling network policy, or coordinating work across multiple sprites.
---

You are managing remote Sprite VMs from a local machine using the `sprite` CLI. This skill covers the local-side CLI for controlling Sprites externally. (Sprites also have built-in agent context at `/.sprite/docs/` for agents running _inside_ the Sprite.)

Sprites are persistent, hardware-isolated Linux VMs on Fly.io with durable filesystems backed by object storage.

## CLI Basics

The `sprite` CLI controls remote Sprites. The `-s` flag specifies which Sprite, `-o` specifies the org.

```bash
# List all sprites
sprite list

# Execute a command on a sprite (blocks until done)
sprite exec -s <name> -- <command>

# Open interactive shell
sprite console -s <name>

# Activate a sprite for the current directory (creates .sprite file)
sprite use <name>
```

When a `.sprite` file exists in the working directory, `-s` can be omitted.

## Executing Commands

`sprite exec` is the primary tool for remote work. Stdout and stderr are returned to the local terminal.

```bash
# Run a single command
sprite exec -s mysprite -- ls -la /home/sprite

# Run a multi-part command (quote or use --)
sprite exec -s mysprite -- bash -c "cd /project && npm test"

# Pipe output locally
sprite exec -s mysprite -- cat /path/to/file > local-copy.txt
```

**Important:** Each `sprite exec` invocation is a separate session. Environment variables, working directory, and shell state do not persist between calls. For stateful work, use `bash -c "..."` to chain commands, or use `sprite console` for interactive sessions.

**Environment variables:** The `-env` flag passes env vars to the remote session, but multiple `-env` flags only apply the **last** one. Use comma-separated format for multiple vars:

```bash
# WRONG — only BAR is set
sprite exec -s mysprite -env "FOO=1" -env "BAR=2" -- env

# RIGHT — both are set
sprite exec -s mysprite -env "FOO=1,BAR=2" -- env
```

## File Transfer

There is no dedicated file transfer command. Use `sprite exec` with `cat` for pulling files, or pipe content in:

```bash
# Pull a file from a sprite
sprite exec -s mysprite -- cat /path/on/sprite > local-file.txt

# Pull a binary file
sprite exec -s mysprite -- base64 /path/to/binary | base64 -d > local-file.bin

# Push a file to a sprite (via stdin)
cat local-file.txt | sprite exec -s mysprite -- bash -c "cat > /path/on/sprite"

# For heavier file work, use SSHFS via proxy
sprite proxy 2222  # then sshfs sprite@localhost:/home/sprite /mnt/sprite -p 2222
```

## Checkpoints

Checkpoints capture the writable overlay of the Sprite's filesystem. They are fast (sub-second, copy-on-write) and cheap.

```bash
# Create a checkpoint (with optional comment)
sprite checkpoint create -s mysprite
sprite checkpoint create -s mysprite -m "before risky refactor"

# List checkpoints
sprite checkpoint list -s mysprite

# Restore to a checkpoint (destructive — drops current session and all changes since)
sprite restore <checkpoint-id> -s mysprite
```

**Checkpoint aggressively.** Before any risky operation, before switching contexts, whenever something is working. Checkpoints are nearly free.

The last 5 checkpoints are also mounted inside the Sprite at `/.sprite/checkpoints/` for direct file-level inspection without restoring.

## Networking

Each Sprite gets a public HTTPS URL at `https://<name>-<org>.sprites.dev/`, routing to port 8080 by default.

```bash
# Show the sprite's URL and auth mode
sprite url -s mysprite

# Make the URL public (no auth required)
sprite url update --auth public -s mysprite

# Restore authenticated mode
sprite url update --auth default -s mysprite

# Forward remote ports to local machine
sprite proxy 8080 3000 -s mysprite
```

Network egress policy is managed via the Sprites REST API, not the CLI:

```bash
# View current network policy (from inside the sprite)
sprite exec -s mysprite -- cat /.sprite/policy/network.json

# Update network policy (from outside, via API)
sprite api -s mysprite POST /policy/network \
  -d '{"rules": [{"include": "defaults"}, {"domain": "custom-api.com", "action": "allow"}]}'
```

Network policy can only be modified externally. The Sprite cannot change its own policy.

## Services

Services are long-running processes inside a Sprite that persist across reboots and hibernation.

```bash
# List services
sprite exec -s mysprite -- sprite-env services list

# Create a service
sprite exec -s mysprite -- sprite-env services create <name> --cmd <binary> --args "<args>"

# Get service status
sprite exec -s mysprite -- sprite-env services get <name>

# View service logs
sprite exec -s mysprite -- cat /.sprite/logs/services/<name>.stderr.log
```

One service can be designated as the HTTP service (receives proxied requests on the Sprite's URL).

## Multi-Sprite Coordination

When working across multiple Sprites, use `sprite list` to see the fleet, then target each by name:

```bash
# Run the same command across all sprites
for s in $(sprite list); do
  echo "=== $s ==="
  sprite exec -s "$s" -- <command>
done
```

Each Sprite is fully isolated — no shared mutable state. Coordinate through explicit communication: files in shared Tigris buckets, HTTP endpoints, or Git repos.

## Lifecycle

```bash
# Create a new sprite
sprite create <name>
sprite create -o <org> <name>

# Destroy a sprite (irreversible)
sprite destroy <name>
```

Sprites auto-sleep when idle (no active commands, TCP connections, TTY sessions, or running Services). They wake automatically on the next `sprite exec`, `sprite console`, or HTTP request to their URL. Anything on disk persists across sleep cycles. Running processes do not — use Services for daemons.

## SSH Agent Forwarding and Git

The Mac's SSH config forwards the 1Password SSH agent to `*.ts.net` hosts (Sprites with Tailscale). This enables:

- **SSH git operations** — clone, push, and pull private repos directly over SSH without PATs
- **Commit signing** — `install.sh` enables `commit.gpgsign = true` when a forwarded agent is detected, using the first key from the agent

Clone repos via the Tailscale hostname:

```bash
ssh <sprite-hostname> git clone git@github.com:<org>/<repo>.git /home/sprite/<repo>
```

## Internal Sprite Paths

When running commands on a Sprite, these paths are useful:

- `/.sprite/api.sock` — internal API Unix socket
- `/.sprite/policy/network.json` — read-only network policy
- `/.sprite/checkpoints/` — last 5 checkpoints mounted for inspection
- `/.sprite/logs/services/` — service logs
- `/.sprite/docs/` — platform documentation (agent-context.md, languages.md, docker.md)
- `/home/sprite/` — user home directory

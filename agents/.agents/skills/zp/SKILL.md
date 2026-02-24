---
name: zp
description: Use this skill when the user wants to open, create, or manage projects across local macOS, Apple Containers, and Fly.io Sprites using the zp CLI.
---

You are helping the user manage development projects with `zp`, a Zed project launcher that works across local macOS, Apple Containers, and Fly.io Sprites.

## What zp Does

`zp` opens projects in Zed across three backends:

- **local** — `~/github/owner/name` on macOS
- **container** — Apple Container (macOS 26+), projects at `/home/klundstedt/github/owner/name`
- **sprite** — Fly.io Sprite (remote VM), projects at `/home/klundstedt/github/owner/name`

All backends use the `~/github/owner/name` path convention. New machines are bootstrapped with dotfiles automatically.

## Usage

```
zp [owner/name | name] [--backend local|container|sprite] [--machine <name>] [--org <org>]
```

## Non-Interactive Commands (Use These)

When calling `zp` programmatically, always provide all arguments to avoid TTY prompts:

```bash
# Open an existing project (fully specified)
zp owner/name --backend container --machine dev

# Create a new container, bootstrap it, clone repo, open in Zed
zp owner/name --backend container --machine new-machine-name

# Open locally
zp owner/name --backend local

# Open on a sprite
zp owner/name --backend sprite --machine mysprite
```

When `--machine` names a machine that doesn't exist, `zp` creates it, bootstraps dotfiles, and clones the project — all non-interactively.

## Interactive Commands (Require TTY)

These invoke fzf and are only usable when the user is at a terminal:

```bash
# Browse all projects across all backends
zp

# Search by repo name (fzf if multiple matches)
zp gitlake

# Search by owner/name (offers to clone if not found)
zp owner/name

# Browse projects on a specific backend
zp --backend container
zp --backend container --machine dev
```

## Backends

Backends are plug-in shell scripts in `~/.local/bin/zp-backends/`. Each implements:

| Function | Purpose |
|---|---|
| `backend_available` | Check if CLI is installed |
| `backend_list` | List machines |
| `backend_create <name>` | Create a machine |
| `backend_start` | Start/wake a machine |
| `backend_ensure_ssh` | Set up SSH, return `user@host[:port]` |
| `backend_exec <cmd>` | Run a command via native transport |

## Common Agent Tasks

### Open a project the user asks about

```bash
# Determine where it lives, then open it
zp owner/name --backend container --machine dev
```

### Check what projects exist on a machine

```bash
# List projects via backend_exec (no SSH needed)
container exec dev bash -c "find /home/klundstedt/github -mindepth 2 -maxdepth 2 -type d 2>/dev/null"
```

### Clone a new repo onto an existing machine

```bash
# zp handles clone automatically if the project doesn't exist on the target
zp owner/name --backend container --machine dev
```

### Create a fresh environment for a project

```bash
# New machine name → creates machine, bootstraps, clones, opens
zp owner/name --backend container --machine fresh-env
```

## Important Notes

- GitHub owner in the path (e.g. `kylelundstedt`) is separate from the OS user (`klundstedt`).
- `--backend local --machine X` is an error — local backend has no machines.
- Stopped containers are started automatically. Sprites auto-wake on connection.
- Bootstrap runs `install.sh --no-prompt` from the dotfiles repo on new machines.

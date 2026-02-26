# Linux

## Platform Notes

- Installer prefers native package managers (APT when available) for core CLI tools
- Homebrew on Linux is optional for core tools, but used for `--include-heavy` packages
- Shell change targets `/usr/bin/zsh`; in non-interactive mode it may be skipped without sudo/root
- Claude MCP servers use remote HTTP transport (OAuth for MotherDuck/Tigris, PAT from 1Password for GitHub)

## Testing on Linux

To test the Linux installation path locally, you can use a one-off Docker container that mimics a fresh environment.

This command uses the official `uv` image (which has Python, Curl, and Git) but mimics a clean start by ensuring dependencies are installed before running the script:

```bash
docker run --rm -it ghcr.io/astral-sh/uv:python3.12-bookworm bash -c "apt-get update && apt-get install -y sudo zsh && curl -fsSL https://raw.githubusercontent.com/kylelundstedt/dotfiles/master/install.sh | bash; exec zsh -l"
```

Alternatively, you can use the included test script if you have OrbStack installed:

```bash
./test-install.sh
```

This uses OrbStack's Linux VM to verify the installation works on Linux.

## OrbStack (Local Linux VMs on macOS)

[OrbStack](https://orbstack.dev/) provides fast, lightweight Linux VMs on macOS.

```bash
# Create a new Ubuntu VM
orb create ubuntu my-ubuntu

# Shell into the VM
orb -m my-ubuntu

# Run a command on the VM
orb -m my-ubuntu uname -a

# Bootstrap dotfiles on the VM
orb -m my-ubuntu bash -c "curl -fsSL https://raw.githubusercontent.com/kylelundstedt/dotfiles/master/install.sh | bash"

# List all VMs
orb list

# Delete a VM
orb delete my-ubuntu
```

## Fly.io Sprites (Cloud VMs)

[Sprites](https://fly.io/blog/design-and-implementation/) are lightweight, persistent cloud VMs from Fly.io that create in seconds.

```bash
# Login to Fly.io (first time only)
sprite login

# Create a new sprite
sprite create my-sprite

# Shell into an existing sprite
sprite console -s my-sprite

# Run a command on a sprite
sprite exec -s my-sprite uname -a

# Bootstrap dotfiles on a sprite
sprite exec -s my-sprite bash -c "curl -fsSL https://raw.githubusercontent.com/kylelundstedt/dotfiles/master/install.sh | bash"

# List all sprites
sprite list

# Destroy a sprite
sprite destroy -s my-sprite
```

Sprites automatically sleep when inactive and wake instantly on connection, keeping costs minimal.

## Local Sprites (Apple Container)

### Why Local Sprites

If you use Claude Code or Codex regularly, you've probably ended up running `--dangerously-skip-permissions` on your Mac. The alternative — approving every file edit, shell command, and tool call — kills throughput on anything non-trivial. But dangerous mode gives the agent full access to your home directory, credentials, running processes, and network. A bad tool call, a prompt injection, or a plain mistake can touch anything your user account can.

Devcontainers don't fix this. They share the host kernel and typically mount broad host state (home directory, Docker socket, SSH agent) for ergonomics. They're convenient for human development workflows, not a safety boundary for autonomous agents.

Apple `container` runs each OCI container inside a dedicated lightweight VM on macOS — a hypervisor boundary with a separate guest kernel, not just namespace isolation. This is the same isolation model as remote Sprites: the agent can have dangerous permissions inside the VM without risking your host. The difference is that local sprites are free and have no network latency.

### Prerequisites

- macOS 26+ (Tahoe) on Apple silicon
- Apple `container` CLI — installed by `install.sh`'s apps layer if not present
- Start the daemon: `container system start`

### Base Image

Create `Dockerfile.sprite-local`:

```dockerfile
FROM docker.io/ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
  ca-certificates \
  curl \
  git \
  jq \
  ripgrep \
  zsh \
  && rm -rf /var/lib/apt/lists/*

# Optional: install claude/codex CLIs with explicit versions.

WORKDIR /workspace
CMD ["zsh"]
```

This is a baseline — a complete working image also needs the agent CLI and a way to authenticate to git and the AI provider. That's left to the user for now.

### Workflow

Build the image:

```bash
container build --file Dockerfile.sprite-local --tag sprite-local:base .
```

Run a disposable session:

```bash
container run --name sprite-session --interactive --tty --rm sprite-local:base
```

Get code in — `git clone` from inside the VM (the agent authenticates to git, not you). For local-only repos without a remote, use the tar-copy approach from `test-install.sh`:

```bash
# From the host:
tar -cf - -C ~/my-project --exclude=.git . | container exec -i sprite-session tar -xf - -C /workspace
```

Run the agent with dangerous permissions inside the VM. Do your work.

Get code out — `git push` from inside the VM, or tar-copy back to the host.

Exit and discard. Rebuild from the pinned image for the next task.

### Safe-by-Default Guidelines

- Don't mount `~`, `~/.ssh`, `~/.aws`, `~/.config`, or password-store paths.
- Mount only the specific project directory if needed — but prefer `git clone` for stronger isolation.
- Start with zero ambient secrets; inject only what the task needs.
- Don't forward agent sockets (`SSH_AUTH_SOCK`, GPG).
- Prefer non-root inside the VM.
- Rebuild from the pinned image rather than keeping mutable long-lived VMs.

### When to Use Local vs Remote Sprites

|                        | Local Sprite                                             | Remote Sprite                                                  |
| ---------------------- | -------------------------------------------------------- | -------------------------------------------------------------- |
| **Use when**           | Code is trusted, fast iteration needed, repo-local scope | Untrusted code/deps, broad autonomy, secret-adjacent workflows |
| **Isolation**          | Hypervisor on your Mac                                   | Separate hardware, separate network                            |
| **Checkpoint/restore** | Manual (rebuild discipline)                              | First-class platform feature                                   |
| **Cost**               | Free                                                     | Pay per use                                                    |

### References

- [Apple `container`](https://github.com/apple/container) — GitHub repo
- [Tutorial](https://raw.githubusercontent.com/apple/container/main/docs/tutorial.md)
- [Technical overview](https://raw.githubusercontent.com/apple/container/main/docs/technical-overview.md)
- [Sprites docs](https://docs.sprites.dev/)

## Cloud-Init (VM Bootstrap)

If your VM provider supports cloud-init, you can pass a user-data config that installs prerequisites and runs `install.sh --no-prompt` to bootstrap the standard CLI toolchain automatically.

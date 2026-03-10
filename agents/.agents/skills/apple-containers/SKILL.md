---
name: apple-containers
description: Use when creating, configuring, or managing Apple Container VMs on macOS — including user setup, dotfiles, Tailscale, repo cloning, and Zed remote dev.
---

# Apple Containers

Apple `container` runs OCI containers inside lightweight VMs on macOS (hypervisor isolation, not just namespaces). Used for local dev environments with full Linux, SSH access via Tailscale, and Zed remote development.

## Prerequisites

- macOS 26+ (Tahoe) on Apple silicon
- `container` CLI installed (via `install.sh --apps`)
- Daemon running: `container system start`
- A Tailscale auth key (from 1Password or provided by user)

## Creating a Dev Container

Follow these steps in order. Do not skip any step.

### 1. Create and start the container

```bash
container run --name <name> -d --cpus 4 --memory 8G ubuntu:25.04 sleep infinity
```

Naming convention: `ivs-<purpose>` (e.g., `ivs-klundstedt-ac`, `ivs-demo-ac`).

### 2. Install base packages and create user

```bash
container exec <name> bash -c "
    apt-get update -qq && apt-get install -y -qq git curl sudo zsh >/dev/null 2>&1
    useradd -m -s /bin/zsh klundstedt
    echo 'klundstedt ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/klundstedt
    chmod 440 /etc/sudoers.d/klundstedt
"
```

Passwordless sudo is required — `install.sh` uses `sudo` for apt, chsh, systemctl, and tailscale commands. Without `NOPASSWD`, it hangs waiting for a password with no TTY.

### 3. Install and start Tailscale

Tailscale is **required** — it provides the stable hostname for SSH and Zed remote dev. Without it, the container is unreachable from the host.

```bash
# Install Tailscale
container exec <name> bash -c "curl -fsSL https://tailscale.com/install.sh | sh"
```

Start `tailscaled` as a **detached process** — do NOT use `&` inside `container exec` (it creates zombies). Use `container exec -d` instead:

```bash
container exec -d <name> tailscaled --tun=userspace-networking
sleep 2
```

Resolve the auth key and bring Tailscale up:

```bash
TS_AUTHKEY="$(op read 'op://Employee/Tailscale - iv-internal-dev/credential' --account industryvault.1password.com)"
container exec -e "TS_AUTHKEY=$TS_AUTHKEY" <name> tailscale up --authkey "$TS_AUTHKEY" --hostname <name> --ssh
```

The `--ssh` flag is critical — it enables Tailscale SSH, which allows passwordless login to the container using your Tailscale identity. This is how Zed and `ssh <hostname>` connect without needing SSH keys on the container.

Verify connectivity from the host:

```bash
ssh -o StrictHostKeyChecking=accept-new <name> echo ok
```

Do not proceed until this succeeds.

### 4. Install dotfiles

A single command clones the dotfiles repo and runs the full install (CLI tools, stow, Claude Code, MCP servers, skills). The script self-bootstraps — no prior `git clone` needed:

```bash
container exec -u klundstedt <name> bash -c "curl -fsSL https://raw.githubusercontent.com/kylelundstedt/dotfiles/master/install.sh | bash"
```

**Do not skip this step** — without it, Zed's Claude agent will fail with "Query closed before response received."

### 5. Clone project repos

**SSH agent forwarding (preferred):** The Mac's SSH config forwards the 1Password agent to `*.ts.net` hosts. `install.sh` configures GitHub SSH over port 443 on Linux (port 22 is blocked on Apple Containers) and enables git commit signing when the forwarded agent is available. Clone directly over SSH:

```bash
ssh <name> git clone git@github.com:<org>/<repo>.git /home/klundstedt/<repo>
```

**PAT fallback** (if agent forwarding isn't set up): Resolve a GitHub PAT on the Mac, pass it as an ephemeral env var, clone, then scrub the token from the remote URL:

```bash
GITHUB_TOKEN=$(op item get 'GitHub PAT Home' --fields token --reveal --account lundstedts.1password.com)
container exec -u klundstedt -e "GITHUB_TOKEN=$GITHUB_TOKEN" <name> bash -l -c '
    git clone "https://x-access-token:${GITHUB_TOKEN}@github.com/<org>/<repo>.git" ~/<repo>
    git -C ~/<repo> remote set-url origin git@github.com:<org>/<repo>.git
'
```

The `bash -l` ensures `~/.profile` is sourced so PATH includes `~/.local/bin`.

For work repos, use the work PAT and account:

```bash
GITHUB_TOKEN=$(op item get 'GitHub PAT Work' --fields token --reveal --account industryvault.1password.com)
```

### 6. Connect from Zed

Open the project in Zed via CLI using the Tailscale hostname:

```bash
zed ssh://klundstedt@<name>/home/klundstedt/<repo>
```

Do not add `ssh_connections` to `zed/settings.json` — those are ephemeral VM references that don't belong in the dotfiles repo.

## CLI Quick Reference

```bash
container list                          # List containers
container exec <name> <cmd>             # Run command in container
container exec -u klundstedt <name> <cmd>  # Run as klundstedt
container exec -d <name> <cmd>          # Run detached (for daemons)
container exec -e KEY=VAL <name> <cmd>  # Pass env var
container stop <name>                   # Stop container
container start <name>                  # Start stopped container
container rm <name>                     # Delete container
container inspect <name>                # Show container details
container logs <name>                   # View container logs
```

## File Transfer

```bash
# Host to container (pipe via stdin)
cat local-file.txt | container exec -i <name> bash -c "cat > /path/in/container"

# Tar a directory in
tar -cf - -C /local/dir . | container exec -i <name> bash -c "tar -xf - -C /dest"

# Container to host
container exec <name> cat /path/in/container > local-file.txt
```

## Troubleshooting

- **Container won't start**: Run `container system start` to ensure the daemon is running.
- **SSH fails after Tailscale**: Check `tailscale status` inside the container. Verify the hostname matches.
- **install.sh fails**: Check that git and curl are installed (step 2). Run with `bash -x install.sh` for debug output.
- **Zed agent error "Query closed before response received"**: Claude Code isn't installed on the container. Run `install.sh` on the container.
- **Zombie processes from `tailscaled &`**: Never background processes with `&` inside `container exec`. Use `container exec -d` for persistent daemons.

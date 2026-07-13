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

### 3. Install Tailscale and dotfiles

Tailscale is **required** — it provides the stable hostname for SSH, Zed remote dev, and SSH agent forwarding from the Mac's 1Password agent.

Start `tailscaled` as a **detached process** first — do NOT use `&` inside `container exec` (it creates zombies). Use `container exec -d` instead:

```bash
container exec -d <name> bash -c "curl -fsSL https://tailscale.com/install.sh | sh && tailscaled --tun=userspace-networking"
sleep 3
```

Resolve the auth key and bring Tailscale up:

```bash
# Mint an ephemeral tag:dev key via the Tailscale OAuth client (see agent_docs/secrets.md)
_tok=$(curl -fsS -u "$(op read 'op://Employee/Tailscale OAuth Dev/Client ID' --account industryvault.1password.com):$(op read 'op://Employee/Tailscale OAuth Dev/Client secret' --account industryvault.1password.com)" -d grant_type=client_credentials https://api.tailscale.com/api/v2/oauth/token | jq -r .access_token)
TS_AUTHKEY=$(curl -fsS -X POST -H "Authorization: Bearer $_tok" -H "Content-Type: application/json" -d '{"capabilities":{"devices":{"create":{"reusable":false,"ephemeral":true,"preauthorized":true,"tags":["tag:dev"]}}},"expirySeconds":600}' https://api.tailscale.com/api/v2/tailnet/-/keys | jq -r .key)
container exec -e "TS_AUTHKEY=$TS_AUTHKEY" <name> tailscale up --authkey "$TS_AUTHKEY" --hostname <name> --ssh
```

Verify SSH connectivity from the host:

```bash
ssh -o StrictHostKeyChecking=accept-new <name> echo ok
```

Do not proceed until this succeeds.

Now install dotfiles **via Tailscale SSH** so the Mac's 1Password agent is forwarded. This gives install.sh access to GitHub over SSH and enables git commit signing automatically on first login:

```bash
ssh <name> -l klundstedt "curl -fsSL https://raw.githubusercontent.com/kylelundstedt/dotfiles/master/install.sh | bash"
```

**Do not skip this step** — without it, Zed's Claude agent will fail with "Query closed before response received."

### 4. Clone project repos

The Mac's SSH config forwards the 1Password agent to `*.ts.net` hosts (`ForwardAgent yes`). This means `ssh <name>` gives the container access to your GitHub SSH keys — no tokens needed. `install.sh` configures GitHub SSH over port 443 on Linux (port 22 is blocked on Apple Containers). Clone directly:

```bash
ssh <name> -l klundstedt git clone git@github.com:<org>/<repo>.git /home/klundstedt/<repo>
```

Git commit signing is automatically enabled on first login via Tailscale SSH (the shell detects the forwarded agent).

### 5. Connect from Zed

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

---
name: exe-dev
description: Guides working with exe.dev VMs. Use when the user mentions exe.dev, exe VMs, *.exe.xyz, or tasks involving exe.dev infrastructure.
---

# exe.dev

exe.dev provides Linux VMs with persistent disks, instant HTTPS, and built-in auth.

## Documentation

- Docs index: https://exe.dev/docs.md
- All docs in one page (big!): https://exe.dev/docs/all.md
- HTTPS API: https://blog.exe.dev/apis-for-the-restless

## Two interfaces: HTTPS API and SSH

### HTTPS API (preferred for lobby commands)

The HTTPS API at `POST https://exe.dev/exec` is the reliable way to manage VMs. SSH to the exe.dev lobby is intermittently unreliable (connection timeouts).

Mint a bearer token from your registered SSH key:

```bash
PERMS='{"cmds":["ls","new","rm","whoami"]}'
PAYLOAD=$(printf '%s' "$PERMS" | base64 | tr -d '\n=' | tr '+/' '-_')
SIG=$(printf '%s' "$PERMS" | ssh-keygen -Y sign -f ~/.ssh/exe_dev.pub -n v0@exe.dev 2>/dev/null | sed '1d;$d' | tr -d '\n' | tr '+/' '-_' | tr -d '=')
TOKEN="exe0.$PAYLOAD.$SIG"
```

The `ssh-keygen -Y sign` works with 1Password's SSH agent — pass the public key file and the agent handles signing.

Use the token:

```bash
# List VMs
curl -s -X POST https://exe.dev/exec -H "Authorization: Bearer $TOKEN" -d "ls"

# Create VM
curl -s -X POST https://exe.dev/exec -H "Authorization: Bearer $TOKEN" -d "new --name myvm --image ubuntu:24.04"

# Delete VM
curl -s -X POST https://exe.dev/exec -H "Authorization: Bearer $TOKEN" -d "rm myvm"
```

Token permissions control which commands are allowed. The `cmds` array in the permissions JSON must include every command the token needs. Response is always JSON.

### SSH (for VM access)

Direct VM access uses standard SSH:

```bash
ssh <vm>.exe.xyz              # shell
scp file.txt <vm>.exe.xyz:~/  # transfer file
```

Every VM gets `https://<vm>.exe.xyz/` with automatic TLS.

## VM defaults

- **Default user is root** with no sudo installed. If you need a non-root user, install sudo first:
  ```bash
  ssh <vm>.exe.xyz "apt-get update -qq && apt-get install -y -qq sudo && useradd -m -s /bin/bash myuser && echo 'myuser ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/myuser"
  ```
- **Image:** `ubuntu:24.04` is the standard choice. exe.dev also offers `boldsoftware/exeuntu`.

## VM naming rules

- Names cannot end with `-<digits>` (e.g. `test-123` is rejected, `test-abc` works)
- Hyphens are allowed elsewhere in the name
- The name becomes the subdomain: `<name>.exe.xyz`

## SSH config

The exe.dev SSH key must be pinned to avoid 1Password's agent offering wrong keys:

```
Host exe.dev *.exe.xyz
  IdentitiesOnly yes
  IdentityFile ~/.ssh/exe_dev.pub
```

The private key lives in 1Password ("SSH Key - exe.dev" in Employee vault). Only the public key is on disk at `~/.ssh/exe_dev.pub`.

## Working in scripts and agents

- **Prefer HTTPS API** for lobby commands (`ls`, `new`, `rm`). SSH to `exe.dev` is unreliable in automated contexts.
- **Use SSH multiplexing** for repeated VM access to avoid connection overhead:
  ```bash
  ssh -o ControlMaster=auto -o ControlPath=/tmp/ssh-%r@%h-%p -o ControlPersist=300 <vm>.exe.xyz
  ```
- **Accept new host keys** non-interactively: `-o StrictHostKeyChecking=accept-new`
- **Connection timeout:** Use `-o ConnectTimeout=30` for VM SSH — new VMs take a few seconds to become reachable.

## Install Dotfiles

After creating a new VM, install dotfiles to get CLI tools, shell config, Claude Code, MCP servers, and skills. The script self-bootstraps — no prior `git clone` needed:

```bash
ssh <vm>.exe.xyz "curl -fsSL https://raw.githubusercontent.com/kylelundstedt/dotfiles/master/install.sh | bash"
```

For persistent dev environments, pass a Tailscale auth key:

```bash
TS_AUTHKEY="$(op read 'op://Employee/Tailscale - iv-internal-dev/credential' --account industryvault.1password.com)"
ssh <vm>.exe.xyz "TS_AUTHKEY='$TS_AUTHKEY' bash -c 'curl -fsSL https://raw.githubusercontent.com/kylelundstedt/dotfiles/master/install.sh | bash'"
```

**Do not skip this step** — without it, Claude Code and other agent tooling won't be available on the VM.

## SSH Agent Forwarding and Git

The Mac's SSH config forwards the 1Password SSH agent to `*.ts.net` hosts (exe.dev VMs with Tailscale). This enables:

- **SSH git operations** — clone, push, and pull private repos directly over SSH without PATs
- **Commit signing** — `install.sh` enables `commit.gpgsign = true` when a forwarded agent is detected, using the first key from the agent

Clone repos via the Tailscale hostname:

```bash
ssh <vm-hostname> git clone git@github.com:<org>/<repo>.git ~/<repo>
```

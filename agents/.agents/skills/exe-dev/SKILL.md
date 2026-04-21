---
name: exe-dev
description: Guides working with exe.dev VMs. Use when the user mentions exe.dev, exe VMs, *.exe.xyz, or tasks involving exe.dev infrastructure.
---

# exe.dev

exe.dev provides Linux VMs with persistent disks, instant HTTPS, and built-in auth.

## Documentation

- Docs index: https://exe.dev/docs.md
- All docs in one page (big!): https://exe.dev/docs/all.md
- HTTPS API reference: https://exe.dev/docs/https-api.md
- HTTPS API introduction (blog): https://blog.exe.dev/apis-for-the-restless

## Three interfaces

exe.dev officially documents three equal interfaces for VM management: **SSH**, **SSH API** (programmatic SSH), and **HTTPS API**. All use identical command syntax — the HTTPS API is "the SSH API shoved into a POST body." None is officially labeled preferred; pick based on context.

| Interface | When to use                                                                                        |
| --------- | -------------------------------------------------------------------------------------------------- |
| SSH       | Interactive lobby work; familiar unix-y experience                                                 |
| SSH API   | Scripts where you already have the SSH agent loaded                                                |
| HTTPS API | Scoped / time-limited tokens; environments where outbound port 22 is blocked; automation hardening |

### Lobby connection rate limiting

The `exe.dev` lobby silently drops inbound TCP SYNs when you exceed a per-source-IP connection rate (exact threshold undocumented). Empirically confirmed 2026-04-21: a burst of 5 `ssh exe.dev <cmd>` calls 0.5s apart produced 5/5 timeouts at port 22, and the source IP remained blocked at the TCP layer for minutes afterward. This is almost certainly intentional anti-abuse behavior, not instability.

**Avoid tripping it:**

- **Enable SSH multiplexing for `Host exe.dev`** (see "SSH config" below) — one persistent connection carries many commands, so repeated `ssh exe.dev` calls stay under the threshold. This is the single most important config for interactive use.
- **Use the HTTPS API for scripts or agents** that need to issue many lobby commands. Its rate limit is per SSH key (documented) rather than a silent per-IP block.

Direct VM SSH (`ssh <vm>.exe.xyz`) is a different endpoint and does not show this behavior.

### Direct VM access (SSH only)

```bash
ssh <vm>.exe.xyz              # shell
scp file.txt <vm>.exe.xyz:~/  # transfer file
```

Every VM gets `https://<vm>.exe.xyz/` with automatic TLS.

## HTTPS API and scoped tokens

The HTTPS API's distinguishing feature is SSH-signed bearer tokens with scoped permissions — useful for handing limited authority to agents, scripts, or CI jobs without giving out your full SSH key.

Token format: `exe0.<base64url-payload>.<base64url-signature>`. Payload is signed JSON with four fields:

| Field  | Purpose                                                                                                  |
| ------ | -------------------------------------------------------------------------------------------------------- |
| `cmds` | Explicit command allowlist. Parent commands do NOT grant subcommands (`ssh-key` ≠ `ssh-key list`)        |
| `exp`  | Unix expiration timestamp. Docs "strongly recommend always setting `exp`" even though default is forever |
| `nbf`  | Not-before timestamp (for scheduled tokens)                                                              |
| `ctx`  | Arbitrary signed JSON passed to VMs via `X-ExeDev-Token-Ctx`; app-level authz data                       |

Rate limits are **per SSH key** — use separate keys for independent workloads. No replay protection, so keep tokens short-lived. 8KB max.

### Minting a token

```bash
PERMS='{"cmds":["ls","new","rm","whoami"],"exp":1800000000}'
PAYLOAD=$(printf '%s' "$PERMS" | base64 | tr -d '\n=' | tr '+/' '-_')
SIG=$(printf '%s' "$PERMS" | ssh-keygen -Y sign -f ~/.ssh/exe_dev.pub -n v0@exe.dev 2>/dev/null | sed '1d;$d' | tr -d '\n' | tr '+/' '-_' | tr -d '=')
TOKEN="exe0.$PAYLOAD.$SIG"
```

`ssh-keygen -Y sign` works with 1Password's SSH agent — pass the public key file and the agent handles signing.

### Using the token

```bash
curl -s -X POST https://exe.dev/exec -H "Authorization: Bearer $TOKEN" -d "ls"
curl -s -X POST https://exe.dev/exec -H "Authorization: Bearer $TOKEN" -d "new --name myvm --image ubuntu:24.04"
curl -s -X POST https://exe.dev/exec -H "Authorization: Bearer $TOKEN" -d "rm myvm"
```

Response is always JSON.

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

Two blocks: the exe.dev key must be pinned (to avoid 1Password's agent offering other keys), and the lobby host needs connection multiplexing (to avoid the rate-limit block described above).

```
Host exe.dev
  ControlMaster auto
  ControlPath ~/.ssh/sockets/%r@%h-%p
  ControlPersist 600

Host exe.dev *.exe.xyz
  IdentitiesOnly yes
  IdentityFile ~/.ssh/exe_dev.pub
```

Multiplexing is only for `exe.dev` (the lobby). Do not add it for `*.exe.xyz` — VM SSH is a different endpoint, works fine without it, and multiplexing per-VM sockets complicates lifecycle.

The private key lives in 1Password ("SSH Key - exe.dev" in Employee vault). Only the public key is on disk at `~/.ssh/exe_dev.pub`.

## Working in scripts and agents

- **HTTPS API is often the smoother choice for automation** — lobby SSH has observed timeouts, and you can scope the token's `cmds` so an agent only has the authority it needs.
- **Use SSH multiplexing** for repeated VM access to avoid connection overhead:
  ```bash
  ssh -o ControlMaster=auto -o ControlPath=/tmp/ssh-%r@%h-%p -o ControlPersist=300 <vm>.exe.xyz
  ```
- **Accept new host keys** non-interactively: `-o StrictHostKeyChecking=accept-new`
- **Connection timeout:** Use `-o ConnectTimeout=30` for VM SSH — new VMs take a few seconds to become reachable.

## Setting Up a Dev VM

After creating a new VM, set up Tailscale and install dotfiles. Tailscale provides a stable hostname and brings SSH agent forwarding from the Mac's 1Password SSH agent — which handles private repo clone, push, and commit signing uniformly across all dev VM platforms.

### 1. Install Tailscale and dotfiles

Pass `TS_AUTHKEY` and `TS_HOSTNAME` so install.sh handles Tailscale end-to-end:

```bash
TS_AUTHKEY="$(op read 'op://Employee/Tailscale - iv-internal-dev/credential' --account industryvault.1password.com)"
ssh -o ConnectTimeout=30 -o StrictHostKeyChecking=accept-new <vm>.exe.xyz "TS_AUTHKEY='$TS_AUTHKEY' TS_HOSTNAME='<vm>' bash -c 'curl -fsSL https://raw.githubusercontent.com/kylelundstedt/dotfiles/master/install.sh | bash'"
```

Verify Tailscale SSH connectivity from the Mac:

```bash
ssh -o StrictHostKeyChecking=accept-new <vm> echo ok
```

Do not proceed until this succeeds.

### 2. Clone project repos

The Mac's SSH config sets `ForwardAgent yes` for `*.ts.net` hosts. `ssh <vm>` via Tailscale exposes the 1Password SSH agent to the VM, so git operations work with no tokens or keys on the VM:

```bash
ssh <vm> git clone git@github.com:<org>/<repo>.git ~/<repo>
```

`.zshrc` detects the forwarded agent on login and enables commit signing automatically.

**Alternative (rarely needed):** The [exe.dev GitHub integration](https://exe.dev/docs/integrations-github) proxies private-repo clone/fetch/push via `https://<label>.int.exe.xyz/<org>/<repo>.git`, with no secrets on the VM. Useful when Tailscale isn't available, but does not cover commit signing — so typically still ends up paired with agent forwarding anyway.

### 3. Connect from Zed

```bash
zed ssh://<vm>/root/<repo>
```

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

### Connection rate limiting

Both the `exe.dev` lobby AND direct VM SSH (`*.exe.xyz`) silently drop inbound TCP SYNs when you exceed a per-source-IP connection rate (exact threshold undocumented). The 2026-04-21 confirmation was lobby-only — 5 bursty `ssh exe.dev` calls produced 5/5 timeouts. The 2026-04-23 re-test extended the finding: a burst of fresh `ssh <vm>.exe.xyz` calls during VM bootstrap reproduced the same minutes-long port-22 block on the VM endpoint. The endpoints share whatever SYN-drop defense is in play.

**Avoid tripping it:**

- **Enable SSH multiplexing for `Host exe.dev *.exe.xyz`** (see "SSH config" below) — one persistent connection carries many commands and stays under the threshold. This is the single most important config for both interactive and scripted use.
- **Use the HTTPS API for scripts or agents** that need to issue many lobby commands. Its rate limit is per SSH key (documented) rather than a silent per-IP block.
- **Once Tailscale is up on the VM, prefer Tailscale SSH** for further VM access (see "Setting Up a Dev VM" below). Tailnet traffic is WireGuard, not exe.dev's edge — it bypasses the rate limit entirely.

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

- **Image:** `boldsoftware/exeuntu` is the default — `ssh exe.dev new` (no `--image`) creates an exeuntu VM. Use `--image=ubuntu:24.04` for a barebones Ubuntu instead. exeuntu is Ubuntu 24.04 with Bold's overlay (Shelley/Pi agent stack at `~/.config/shelley/` and `~/.pi/`, `~/.zed_server/` pre-staged, kitchen-sink apt list including the Python build deps that broke `uv tool install snowflake-cli` on plain ubuntu).
- **Default user:** depends on image.
  - **exeuntu:** `exedev` (uid 1000, in `sudo` and `docker` groups, NOPASSWD sudo). `$HOME=/home/exedev`. Standard non-root dev pattern.
  - **ubuntu:24.04:** `root` with no sudo installed. To create a non-root user: `ssh <vm>.exe.xyz "apt-get update -qq && apt-get install -y -qq sudo && useradd -m -s /bin/bash myuser && echo 'myuser ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/myuser"`.
- **Pre-existing `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md` on exeuntu** are absolute symlinks into `~/.config/shelley/AGENTS.md`. The dotfiles `install.sh` detects and backs them up (`*.pre-dotfiles.<timestamp>`) before stowing the `agents` package. Bold's underlying file at `~/.config/shelley/AGENTS.md` is preserved.

## VM naming rules

- Names cannot end with `-<digits>` (e.g. `test-123` is rejected, `test-abc` works)
- Hyphens are allowed elsewhere in the name
- The name becomes the subdomain: `<name>.exe.xyz`

## SSH config

The exe.dev key must be pinned (to avoid 1Password's agent offering other keys), and both the lobby and direct VM hosts need connection multiplexing (to avoid the rate-limit block described above):

```
Host exe.dev *.exe.xyz
  IdentitiesOnly yes
  IdentityFile ~/.ssh/exe_dev.pub
  ControlMaster auto
  ControlPath ~/.ssh/sockets/%r@%h-%p
  ControlPersist 600
```

The private key lives in 1Password ("SSH Key - exe.dev" in Employee vault). Only the public key is on disk at `~/.ssh/exe_dev.pub`.

`install.sh` (macOS branch) adds two related stanzas:

```
Host *.exe.xyz *.<tailnet>.ts.net
  User exedev

Host *.exe.xyz
  LocalForward 8765 localhost:8765
```

`User exedev` applies broadly so `ssh <vm>` and `ssh <vm>.exe.xyz` both default to exedev (exeuntu's default user). `LocalForward 8765` is scoped to **the `*.exe.xyz` form only** — the Tailscale name is deliberately left out so routine `ssh <vm>` connections don't race for port 8765. Zed's remote-server SSH keeps a persistent connection open; if the LocalForward were on the Tailscale pattern too, every subsequent terminal `ssh <vm>` would log `bind: Address already in use` and its tunnel would be dead.

**For MCP OAuth flows, use `ssh <vm>.exe.xyz`** — that gets the tunnel. Everyday work uses `ssh <vm>` (Tailscale) and stays clean.

## Working in scripts and agents

- **HTTPS API is often the smoother choice for lobby automation** — you can scope the token's `cmds` so an agent only has the authority it needs.
- **SSH multiplexing is in `~/.ssh/config`** (added by `install.sh`), so repeated `ssh <vm>.exe.xyz` calls reuse one TCP connection. Don't override it with per-call `ControlPath` flags — that fragments the socket pool and undermines the rate-limit mitigation.
- **Accept new host keys** non-interactively on first contact: `-o StrictHostKeyChecking=accept-new`.
- **Connection timeout:** Use `-o ConnectTimeout=30` for VM SSH — new VMs take a few seconds to become reachable.
- **After Tailscale is up, switch to Tailscale SSH for the rest of the work.** See "SSH endpoints" below.

## SSH endpoints — when to use which

A running VM is reachable at two SSH endpoints once dotfiles are installed:

| Endpoint                                | When to use                                                                                                                                                                                                                                                                                                                                          |
| --------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ssh <vm>.exe.xyz` (exe.dev)            | **Bootstrap only.** Required before Tailscale is up (the curl-install + `install.sh` phase). Also useful as fallback if Tailscale on the VM is broken, or from a Mac not on the tailnet.                                                                                                                                                             |
| `ssh <vm>` / `ssh <vm>.dojo-sun.ts.net` | **Default for all post-bootstrap work.** Forwards the 1Password SSH agent (private-repo clone, push, signing — no tokens on VM), bypasses exe.dev's per-IP rate limit, no SSH host-key churn on VM rebuild (Tailscale handles auth via WireGuard, not OpenSSH host keys), and same pattern as Apple Containers and Sprites for cross-platform habit. |

**Rule of thumb:** if Tailscale is up on the VM, reach for `ssh <vm>` first. Reserve `ssh <vm>.exe.xyz` for the bootstrap window and emergencies.

### VM-to-VM access

exe.dev VMs have `/dev/net/tun` and `CAP_NET_ADMIN`, so `install.sh` runs `tailscaled` in **kernel mode** — a real `tailscale0` interface, kernel routes for `100.0.0.0/8`, MagicDNS wired into the system resolver. Plain `ssh <vm>` works VM-to-VM the same way it does from the Mac.

```bash
# from inside any exe.dev VM (use the username that matches the destination's image)
ssh exedev@gitlake 'cd ~/dotfiles && git pull && ./install.sh'   # exeuntu
ssh root@gitlake 'cd ~/dotfiles && git pull && ./install.sh'     # ubuntu:24.04
```

This requires the Tailscale ACL to permit `tag:dev` → `tag:dev` for both the network grant and the SSH rule (admin console). The SSH rule's `users` list must include whichever destination user(s) you log in as — typically `exedev` for exeuntu, `root` for ubuntu:24.04.

**Userspace-mode fallback.** If `/dev/net/tun` isn't available (some Apple Containers configs, Sprite), `install.sh` falls back to `tailscaled --tun=userspace-networking`. Plain `ssh <vm>` won't work in that mode (no kernel route to tailnet IPs); use `tailscale ssh <vm>` instead, which proxies through tailscaled's userspace TCP stack.

## Setting Up a Dev VM

A default setup script (`exe-setup.sh`) is registered via `ssh exe.dev defaults write` so every new VM automatically gets Tailscale + dotfiles. No piping needed — just three commands:

### 1. Create VM + clone repo (~4s)

```bash
ssh exe.dev new --name=<vm>
ssh exe.dev integrations attach <github-label> vm:<vm>
ssh -o ConnectTimeout=30 -o StrictHostKeyChecking=accept-new <vm>.exe.xyz \
  "git clone https://<github-label>.int.exe.xyz/<org>/<repo>.git ~/<repo>"
```

The default setup script (`exe-setup.sh` in the dotfiles repo) runs at first boot and:

- Deletes stale Tailscale nodes with the same hostname (prevents `-2` suffix)
- Generates a single-use ephemeral auth key via the `tailscale-api` HTTP proxy integration
- Starts `tailscaled` and authenticates (Tailscale SSH available ~18s after VM creation)
- Runs `install.sh` in the background (full dotfiles ~60s)

To set the default (one-time, already done):

```bash
ssh exe.dev "defaults write dev.exe new.setup-script 'curl -fsSL https://raw.githubusercontent.com/kylelundstedt/dotfiles/master/exe-setup.sh | bash'"
```

The `tailscale-api` integration holds the Tailscale API bearer token — the VM never sees it. Created once via:

```bash
ssh exe.dev integrations add http-proxy --name tailscale-api \
  --target https://api.tailscale.com \
  --bearer "$(op read 'op://Employee/Tailscale - API Key/credential' --account industryvault.1password.com)" \
  --attach auto:all
```

### 2. Clone project repos

The exe.dev GitHub integration handles clone/push with no tokens on the VM:

```bash
ssh <vm>.exe.xyz "git clone https://<label>.int.exe.xyz/<org>/<repo>.git ~/<repo>"
```

For commit signing, use Tailscale SSH (`ssh <vm>`) which forwards the 1Password SSH agent. `.zshrc` detects the forwarded agent on login and enables commit signing automatically.

### 3. MCP servers

Three of five MCP servers connect automatically via exe.dev HTTP proxy integrations — no setup needed on new VMs:

| Server | Proxy integration | Auth |
|---|---|---|
| motherduck | `motherduck-mcp.int.exe.xyz` | Static bearer token (auto) |
| github-home | `github-mcp-home.int.exe.xyz` | Static bearer token (auto) |
| github-work | `github-mcp-work.int.exe.xyz` | Static bearer token (auto) |
| tigris | — | OAuth (one-time browser dance) |
| readwise | — | OAuth (one-time browser dance) |

`install.sh` registers all five servers automatically. The three proxy-based servers show "Connected" immediately after install; Tigris and Readwise show "Needs authentication" until the OAuth flow is completed.

**OAuth flow for Tigris/Readwise (one-time per VM):**

```bash
ssh <vm>.exe.xyz                # use the .exe.xyz form — carries LocalForward 8765
claude                          # inside the VM, start an interactive session
# /mcp → pick a server marked "Needs authentication" → Authenticate
# claude prints an http://localhost:8765/... URL — open it in the Mac browser
```

The Tailscale form (`ssh <vm>`) deliberately does **not** carry the LocalForward — Zed's persistent remote-server SSH would otherwise race for port 8765 on every routine connection. Do one OAuth flow at a time across VMs because of the port-8765 bind. Tokens cache per VM under `~/.claude/`, so this is a one-time-per-VM step per server.

### 4. Connect from Zed

Use the Tailscale hostname (short form works thanks to the canonicalization block in `~/.ssh/config`). The user and home path depend on the image:

```bash
zed ssh://exedev@<vm>/home/exedev/<repo>   # exeuntu (default)
zed ssh://root@<vm>/root/<repo>            # ubuntu:24.04
```

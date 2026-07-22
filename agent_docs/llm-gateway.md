# Self-hosted LLM gateway (Claude + Codex subscriptions)

> Status: built and verified on `klundstedt-mini` 2026-07-19. **Current form is
> a host-level setup** (LaunchAgents + brew Caddy) — the expedient path used to
> prove the concept. The **target form is an Apple Container appliance VM with
> its own repo** (see "Target architecture"). This doc covers both; no secrets
> here — credentials live in gitignored host paths noted below.

## What it is

A self-hosted gateway that lets any agent use the **ChatGPT/Codex and Claude
subscriptions** (not metered API keys) behind an OpenAI-/Anthropic-compatible
endpoint. It is the _credential-sovereignty_ companion to the _compute
sovereignty_ of local AC VMs: the subscription OAuth tokens stay on owned
hardware, and no consumer (local VM or remote tailnet VM) ever holds a provider
credential.

It reproduces what the exe.dev `llm` integration does — terminate credentials at
a gateway, expose a stable endpoint — but on hardware we control, and it adds
**Claude Max access that the exe.dev gateway does not offer today.**

Engine: **CLIProxyAPI** (github.com/router-for-me/CLIProxyAPI) — wraps
Codex/Claude/Gemini/Grok OAuth logins, serves OpenAI/Anthropic/Gemini-compatible
APIs. Vetted at v7.2.91 / commit fde40c5 (2026-07-19): no exfiltration; contacts
only legitimate upstreams. Re-vet on upgrade.

## Current form (host-level on klundstedt-mini)

```
CLIProxyAPI 127.0.0.1:8317  (subscription tokens ~/.cli-proxy-api, local api-key)
   ▲ Caddy injects api-key, routes /anthropic + /openai
   ├─ 192.168.64.1:8484  vmnet bridge   → local AC guests, NO token
   └─ 127.0.0.1:8485     tailnet door   → `tailscale serve --https=8443`, TOKEN required
```

| Piece                | Path / location                                                                                                             |
| -------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| CLIProxyAPI binary   | `~/.local/bin/cli-proxy-api`                                                                                                |
| CLIProxyAPI config   | `~/.config/iv-sandbox/cli-proxy-api.yaml` (host 127.0.0.1:8317; api-keys set; control panel + auto-update off; plugins off) |
| Subscription tokens  | `~/.cli-proxy-api/` (dir 0700, files 0600) — `codex-*.json`, `claude-*.json`                                                |
| Internal api-key     | `~/.config/iv-sandbox/cpa-key.txt` (0600)                                                                                   |
| Caddy config         | `~/.config/iv-sandbox/Caddyfile` (0600)                                                                                     |
| Tailnet access token | `~/.config/iv-sandbox/gateway-access-token.txt` (0600)                                                                      |
| LaunchAgents         | `com.industryvault.iv-sandbox-cli-proxy` (CLIProxyAPI), `-llm-gateway` (Caddy)                                              |
| Tailnet URL          | `https://klundstedt-mini.dojo-sun.ts.net:8443` (dedicated port; 443 is hub-mcp)                                             |

Setup that was done (for reproduction):

1. Download + checksum-verify the arm64 CLIProxyAPI release; install to
   `~/.local/bin`; write the hardened config (localhost bind, required
   `api-keys`, `disable-control-panel`, `disable-auto-update-panel`,
   `plugins.enabled: false`, `usage-statistics-enabled: false`); pre-create
   `~/.cli-proxy-api` at 0700.
2. OAuth logins (interactive, one browser approval each; callback to a localhost
   port on the host — SSH-tunnel that port if driving remotely):
   `cli-proxy-api -config … -codex-login -no-browser`, then `-claude-login`.
3. Caddy front: `/anthropic/*` and `/openai/*` → `127.0.0.1:8317`, injecting the
   internal api-key. **Only `header_up Authorization "Bearer <key>"`** — do NOT
   also `header_up -Authorization` (the delete runs after the set and nukes it).
4. Tailnet door site keyed `http://:8485` (any Host) with `bind 127.0.0.1`, then
   `tailscale serve --bg --https=8443 http://127.0.0.1:8485`. The site MUST be
   any-Host, not `http://127.0.0.1:8485` — `tailscale serve` forwards a
   different Host and a host-specific site returns an empty 200.

## How to use it

**Local AC guest** (e.g. iv-sandbox) — Shelley `shelley.json`:

```json
{ "llm_gateway": "http://192.168.64.1:8484" }
```

No token needed; the bridge is vmnet-isolated.

**Any tailnet VM** (exe.dev, other AC) — `shelley.json`:

```json
{ "llm_gateway": "https://klundstedt-mini.dojo-sun.ts.net:8443" }
```

…and set `ANTHROPIC_API_KEY` and `OPENAI_API_KEY` to the **gateway access
token** (Shelley forwards these to the gateway; Caddy validates and swaps for the
internal key). Access control = tailnet ACL (network) + the token (app).

**Model-ID caveat:** Shelley sends dashed wire names, so Claude models and
`gpt-5.6-{sol,terra,luna}`, `gpt-5.5`, `gpt-5.4`, `gpt-5.4-mini` work. Dead:
`gpt-5.3-codex`/`gpt-5.2-codex` (served as `gpt-5.3-codex-spark`), `gpt-5.4-nano`,
`*-fireworks`, `grok-4.5`. Add CLIProxyAPI `oauth-model-alias` entries to revive
the codex names.

```bash
# List served models
curl -s -H "Authorization: Bearer $(cat ~/.config/iv-sandbox/cpa-key.txt)" \
  http://127.0.0.1:8317/v1/models | jq -r '.data[].id'
# Restart
launchctl kickstart -k gui/503/com.industryvault.iv-sandbox-cli-proxy
launchctl kickstart -k gui/503/com.industryvault.iv-sandbox-llm-gateway
```

## Target architecture (recommended — align with the fleet model)

The host-level form is bespoke. The consistent design, per the same question we
ask of every VM (exeuntu → clone repos → run), is to make the gateway an
**Apple Container appliance VM**, not a pile of host LaunchAgents:

- **AC appliance VM** named e.g. `llm-gateway`, exeuntu base, `--home-mount
none`. It joins the tailnet as its own node and does its **own `tailscale
serve`** — which removes the host Caddy + vmnet-bridge entirely (the VM is the
  endpoint). Subscription tokens live **inside** the isolated VM, not loose in
  the mac home — strictly better custody.
- **Appliance, not dev, profile.** The exeuntu → iv-image → dotfiles chain
  provisions a _dev_ VM (a box you code in). The gateway runs one service, so it
  needs exeuntu (systemd/tailscale/consistency) + its **own service repo** —
  not the full dev toolchain. This is why it's "different": appliance vs. dev,
  not an exception to the provisioning model.
- **Its own GitHub repo**, mirroring the **personal-mcp/hub-mcp precedent** (a
  standalone mini service with its own repo + lifecycle). Contents: hardened
  CLIProxyAPI config template, the login runbook, the systemd unit + a
  `tailscale serve` setup, and provisioning that a `container machine` build (or
  install.sh path) consumes. Keep it **personal** (not baked into the team
  `iv-image`) — it uses personal subscriptions and carries ToS-gray blast
  radius that shouldn't live in the shared image.
- **Consumers unchanged** except the URL becomes `https://llm-gateway.<tailnet>`
  (a clean node name instead of `klundstedt-mini:8443`).

Migration is a re-architecture, not yet done — the current host form works. When
ready: create the repo, build the appliance VM per `apple-container-vms.md`,
re-run the two OAuth logins inside it, point consumers at the new node, then tear
down the host LaunchAgents + Caddy + the `:8443` serve.

## Security & caveats

- **Custody:** all provider/subscription tokens stay on the mini; guests and
  remote VMs hold none. Target form isolates them further inside an AC VM.
- **NOT a gray zone any more — Anthropic addresses this explicitly (verified
  2026-07-22).** This bullet previously called it a gray zone; that was accurate
  when written and is now understated.
  [Claude Code — Legal and compliance](https://code.claude.com/docs/en/legal-and-compliance)
  states OAuth authentication "is designed to support **ordinary use of Claude
  Code and other native Anthropic applications**," that limits "assume
  **ordinary, individual usage** of Claude Code and the Agent SDK," that
  Anthropic "does not permit third-party developers … to route requests through
  Free, Pro, or Max plan credentials on behalf of their users," and that it
  "reserves the right to take measures to enforce these restrictions and may do
  so **without prior notice**." The docs tightened ~2026-02-19; enforcement
  against third-party tools using Pro/Max quota began 2026-04-04. CLIProxyAPI is
  not a native Anthropic application, so the Anthropic half of this gateway sits
  outside the intended scope of subscription OAuth regardless of how few users
  it serves — and is subject to being blocked without warning, which is an
  availability risk as much as a policy one. The OpenAI half is a separate
  question (OpenAI does sanction a device-code flow for ChatGPT accounts, which
  is how exe.dev's own integration works) and has not been assessed here.
- **The goal this gateway was built for has a supported answer.** Running
  `claude` in a terminal on any VM is ordinary use of Claude Code and is fully
  permitted; Claude Code is already installed and individually logged in across
  the fleet. The gateway's distinct value is putting subscription-backed Claude
  into a **non-native client's** model picker (Shelley) — which is the part the
  policy addresses. Do not fan this out to more consumers; see
  [shelley-dual-provider.md](shelley-dual-provider.md).
- **Team scale-out should switch to metered API keys behind a sanctioned
  gateway (e.g. Tailscale Aperture), not subscriptions** — see
  `model-routing-economics.md`.
- **CLIProxyAPI hardening (must persist across upgrades):** localhost bind,
  required `api-keys`, control panel + auto-update off, plugins off, usage stats
  off, `-local-model`. Never enable Home/cluster mode, Postgres/object-store
  backends, or GitStore (all had past credential-handling issues; all off by
  default).

```

```

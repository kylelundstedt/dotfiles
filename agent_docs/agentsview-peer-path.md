# AgentsView data path over exe.dev peer integrations

Status: **cut over 2026-09-06.** All 15 exe.dev sources pull through peer
integrations, the collector runs with auth off behind its own proxy, the
sync token is the public fleet constant (model B below, chosen), enrollment is
automatic (`create-vm` + the collector's daily reconcile). The mini is the one
tailnet-path source left. Open items at the end.

## Why

The collector pulls every source over the tailnet with a static per-host
bearer token that is hand-placed on the VM and hand-copied into the
collector's `[[remote_hosts]]`. Nothing exe.dev-governed sits on that path,
and nothing automates the collector-side half of enrollment since
`new-dev-vm` was retired (2026-08-24): the create-vm skill on iv-provision
creates and provisions a VM but cannot write the collector's config. Three
VMs created 2026-08-29..09-03 were never enrolled and the coverage check was
blind the whole time (agent_docs/monitoring.md). See the 2026-09-06 session
for the full history.

## What was proven on the canary (iv-cmg, 2026-09-06)

| step                                                                                              | result                                                                                                       |
| ------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| peer integration `av-src-iv-cmg` → `https://iv-cmg.exe.xyz:8080/`, attached to `vm:iv-agentsview` | created                                                                                                      |
| daemon on its default tailnet-only bind                                                           | proxy answers **502** — unreachable                                                                          |
| daemon bound `0.0.0.0:8080`, `--require-auth`                                                     | **401** unauth, **200** with the VM's token, via `av-src-iv-cmg.int.exe.xyz`                                 |
| daemon bound `127.0.0.1:8080`, no `--require-auth`                                                | **200** via the integration; direct eth0 `10.42.0.42:8080` and tailnet `100.85.55.104:8080` both **refused** |
| `--public-url`                                                                                    | must be `https://iv-cmg.exe.xyz:8080` — the Host that arrives is the target's, not the `int.exe.xyz` name    |
| collector `[[remote_hosts]]` with no `token`                                                      | rejected: `token is required for http`                                                                       |
| `token = "peer"` placeholder, no bearer at the edge                                               | source answers **401** — the sync endpoint checks `auth_token` even without `--require-auth`                 |
| real token in the collector block                                                                 | **synced 1 Shelley session, 115 messages**                                                                   |
| real token on the integration (`--bearer`), placeholder in the collector block                    | **sync succeeds** — the edge's injected `Authorization` wins over the collector's                            |

Current canary state, left in place: iv-cmg bound to loopback with no
`--require-auth` via a user-unit drop-in
(`~/.config/systemd/user/agentsview-source.service.d/canary.conf`), its token
held on the peer integration, `token = "peer"` in the collector block. The
collector was restarted to load the block (it does not re-read config).

## Design

Each VM does the write it already has authority for; no VM writes into another.

1. **iv-provision (create-vm)** creates the VM and, in the same step, the
   peer integration `av-src-<vm>` → `https://<vm>.exe.xyz:8080/` attached
   to `vm:iv-agentsview`. Its `api-exe-new` token widens from `new` to
   `new,integrations add`.
2. **provision-iv.sh** binds the source daemon to `127.0.0.1:8080` with
   `--public-url https://<vm>.exe.xyz:8080` and no `--require-auth`. The
   exe.dev auth proxy is the only way in. The tailnet is no longer on the
   data path (the `tailscale ip` prerequisite in `agentsview-source-daemon`
   goes away).
3. **iv-agentsview** runs a daily reconcile: list its own attached
   integrations through `reflection.int.exe.xyz/integrations`, ensure a
   `[[remote_hosts]]` block for every `av-src-*`, restart itself when the
   config changed. `agentsview-coverage` (already on the collector)
   confirms the result against the `ls` inventory, so a VM created outside
   create-vm shows up as uncovered rather than silently missing.
4. **klundstedt-mini** stays on the tailnet path with its own token: it is
   not an exe.dev VM.

## The open decision: where the sync token lives

AgentsView's HTTP sync needs a token that matches the source's `auth_token`,
even with `--require-auth` off. Two models, both proven above:

- **A. Per-host token, held at the edge.** create-vm mints it, puts it on
  the peer integration as `--bearer`, and passes it into the VM through the
  provisioning `--prompt` so provision-iv.sh writes `source.env`. Keeps the
  per-host property provision-iv.sh documents. Cost: the token transits the
  `new --prompt` (visible in that VM's Shelley prompt and journal), and
  create-vm becomes the only correct way to make a VM.
- **B. Fleet-wide constant, treated as non-secret.** Baked into
  provision-iv.sh and every collector block. Zero secret handling, fully
  automatic, a VM made any way enrolls the same. Reverses the per-host
  rationale in provision-iv.sh — which was written for a tailnet-exposed
  daemon. With a loopback bind, reaching the daemon requires a peer
  integration attached to your VM in this account: the edge is the
  boundary, the token is a protocol formality.

Recommendation: **B**. The value the per-host token protected (network
reachability of the archive) is now enforced by exe.dev, mechanically.

## Cutover record (2026-09-06)

- **iv-provision 3.0.23** (PR #50): daemon on `127.0.0.1:8080`, `--public-url
https://<vm>.exe.xyz:8080`, no `--require-auth`, `AGENTSVIEW_FLEET_TOKEN`
  written on every provision; `create-vm` creates `av-src-<name>` after `new`
  (its token widened to `integrations add`; `attach`/`edit`/`remove`/`rm`
  verified 403).
- **Collector** (`provisioning/iv-agentsview/`): unit rewritten (loopback, no
  auth; `auth_token`/`require_auth` stripped from config), `agentsview-reconcile`
  runs as `ExecStartPre` of the daily coverage service, coverage gained the
  public-port check (`api-exe-ls` token now `ls` + `share show`). iv-provision's
  `agentsview` reader integration recreated without its stale bearer.
- **Fleet**: every VM re-provisioned at 3.0.23 in place (`upgrade-vm` path),
  one at a time, then reconciled and synced. `iv-ave-adapters` and `aom-build`
  time out on SSH from the mini both via `<vm>.exe.xyz` and the tailnet;
  relaying through the lobby (`ssh exe.dev ssh <vm> …`) works. `agentsview
sync --host` right after re-creating an integration can 401/502 for a
  minute while the edge catches up — probe `/api/v1/version` first.
- **Found**: `aom-build` (8 sessions) and `fannie-sflpd-poc` (15) had never
  been collected. First full coverage run on the new path: 16 covered, 5
  excused, 0 uncovered, 15 peer sources private.
- **Cleanup done**: mini Keychain `agentsview:auth-token` deleted (retired
  collector token, no reader); `provisioning/keys.manifest` row updated.

### Open

- **1Password**: the 12 per-host source tokens and the collector UI token in
  "AgentsView" are dead; only the mini's source token is live.
  Delete them (Kyle).
- **Shared VMs.** A user the VM is shared with reaches its alternate ports, so
  on the peer path they can read that VM's own archive unauthenticated. Today
  only `kgl-songs` (3 users); the coverage check reports it every run as a
  note, not a failure. Decide: acceptable (their own collaboration sessions),
  or exclude `kgl-songs` from collection.
- **Tailnet grants** allowing fleet → `:8080` are now unused by the fleet
  (only the mini still serves there); tighten in the console when convenient.
- **Overlay** `install.sh` fails on `iv-foundry-stage2`, `iv-entire-agent-shelley`
  and `iv-ave-adapters`: stow conflict, `.config/shelley/hooks/new-conversation`
  is a real file there, not a link. Pre-existing (provision-iv.sh does not write
  it); those VMs have never had the overlay hooks. Fix by moving the file aside
  and re-running `install.sh`.
- Old create-vm keys `iv-provision-newvm` and `iv-bootstrap` on the exe.dev
  account are probably orphaned by the rotation; confirm and delete (Kyle).

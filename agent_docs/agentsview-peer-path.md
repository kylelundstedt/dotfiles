# AgentsView data path over exe.dev peer integrations

Status: **canary proven 2026-09-06 on `iv-cmg`**; fleet cutover and automatic
enrollment not started. Decision pending on the token model (below).

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

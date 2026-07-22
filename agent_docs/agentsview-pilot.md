# AgentsView fleet pilot — unified agent history across machines

Status: **pilot in progress** (approved and Phase 0/1 canaries started
2026-07-22). This is an internal KGL/IV development-fleet pilot, not an IV
Platform product decision.

## Decision

Deploy AgentsView on every active agent-capable exe.dev VM and Apple Container
VM, plus `klundstedt-mini`, and collect their Shelley, Claude Code, and Codex
sessions into one central AgentsView archive on the mini.

The immediate objective is operational:

> One durable, searchable view of agent activity across machines and harnesses,
> surviving VM rebuilds and available through AgentsView's UI, API, MCP, and
> Recall experiments.

This pilot is useful even if AgentsView is never productized by IndustryVault.
The separate product evaluation lives in
`kylelundstedt/iv-docs:reference/agentsview_evaluation.md`.

## Architectural boundary

AgentsView is an **agent-history collector**, not an IV data-substrate adapter.
The pilot must not import transcripts or `shelley.db` into IV Dataset Records,
Subledgers, or the Operating Ledger.

Keep three authority domains distinct:

| Plane                     | Meaning                                                                 |
| ------------------------- | ----------------------------------------------------------------------- |
| AgentsView archive        | Durable normalized record of captured agent work                        |
| Governed operating memory | Reviewed and published rules, procedures, examples, and Memory Releases |
| IV data authority         | Promoted datasets and execution evidence                                |

AgentsView Recall may produce candidate knowledge. A Recall entry is not approved
operating memory merely because it was extracted from a session.

## Pilot topology

```text
Agent-capable hosts

  exe.dev VM ─────────┐
  Apple Container VM ├─> local AgentsView source daemon
  klundstedt-mini ───┘             │
                                   │ authenticated HTTP over Tailscale
                                   ▼
                         central AgentsView on
                           klundstedt-mini
                                   │
                      ┌────────────┼────────────┐
                      │            │            │
                 UI / search    API / MCP   Recall pilot
                                   │
                        consistent SQLite backup
                                   │
                                   ▼
                    encrypted mini backup in Tigris
```

### Why the mini is central for the pilot

`klundstedt-mini` is already the always-on operational host, a persistent
tailnet node, FileVault-encrypted, monitored, and covered by the encrypted
Tigris backup system. Running the first collector there avoids introducing a
second availability dependency before AgentsView has proved useful. It also
indexes the mini's local Claude/Codex sessions directly.

A dedicated Apple Container appliance remains a post-pilot option. AgentsView
is self-contained enough to fit the appliance criterion, but isolation is not
worth another VM lifecycle during initial validation.

### Which machines are in scope

“Fleet” means every active machine on which Shelley, Claude Code, or Codex is
used:

- exe.dev development VMs;
- Apple Container development VMs such as `iv-sandbox`;
- `klundstedt-mini`;
- `klundstedt-mbp` only if agents begin running locally there rather than acting
  solely as a client.

Service-only appliances that do not run an agent harness, such as the target
LLM gateway appliance, do not need AgentsView.

## Collection path

Start with AgentsView's supported authenticated HTTP remote sync:

- one source daemon per agent-capable host;
- one stable configured host name per source;
- one bearer token per source, never a fleet-wide shared token;
- private tailnet transport only;
- central sync at a short interval, initially five minutes;
- standard provider directories auto-discovered unless a host has a nonstandard
  layout.

The collector retains sessions after a source VM disappears, which makes it
suitable for ephemeral exe.dev VMs.

### Tailnet prerequisite

The central collector cannot automate against exe.dev's authenticated web proxy.
Every source VM must be reachable from the mini over Tailscale. `iv-image`
currently leaves tailnet enrollment as an on-demand step, so the pilot must
inventory active agent hosts and either:

1. require `/join-tailnet` before enabling the AgentsView source service; or
2. add approved tagged, one-use tailnet enrollment to the VM provisioning flow.

Do not make auto-enrollment a hidden side effect of installing the binary. It is
a separate network-identity decision.

## Data and retention policy

Agent history is sensitive client/work content, not harmless metadata. It can
contain prompts, thinking, source fragments, shell commands, tool results,
credentials accidentally exposed to tools, email addresses, and model-routing
information.

For the pilot:

- the central `sessions.db` is the durable system of record for **normalized
  captured agent history**;
- it is not approved operating memory or IV dataset authority;
- native records remain producer state on their source hosts;
- permanent byte-for-byte native retention is not required;
- AgentsView's `remote-mirrors/` is sensitive working state, not the backup
  authority;
- raw mirrors receive restrictive permissions and remain only on the
  FileVault-encrypted mini;
- no AgentsView data is shared across a future client boundary.

HTTP remote sync mirrors raw source files, including Shelley's live SQLite/WAL
set. This worked in the evaluation but is not a certified SQLite backup. The
pilot uses it for collection and normalization, not as evidence of a lossless
source snapshot.

## Durable backup

Do not let the ordinary home-directory backup copy the live AgentsView SQLite
file and call that consistent.

Add a pre-backup step that:

1. uses SQLite's online backup mechanism to snapshot central `sessions.db`;
2. writes the snapshot to an included staging path under `~/archives/agentsview`;
3. records timestamp, AgentsView version, size, and SHA-256 in a manifest;
4. verifies `PRAGMA integrity_check` on the snapshot;
5. lets the existing encrypted Tigris backup capture the snapshot;
6. excludes the live AgentsView data directory and `remote-mirrors/` from the
   generic home sync.

Recall lives in `sessions.db` and is included. Derived vector/DuckDB indexes need
not be authoritative backups if they can be rebuilt.

The pilot is not complete until a snapshot restores into a clean data directory
and the restored UI can find sessions from a deleted/rebuilt VM.

## Repository ownership

### `dotfiles`

Owns the operational pilot and personal/host pieces:

- this plan and pilot checklist;
- AgentsView in `provisioning/tools.manifest` as a team tool;
- floating/latest installation on Macs and non-IV personal hosts;
- central collector configuration on the mini;
- macOS LaunchAgent(s) for collection, serving, and snapshot preparation;
- secret retrieval from 1Password/Keychain without committed tokens;
- integration with the mini's backup and monitoring;
- installer and drift tests.

### `iv-image`

Owns the reproducible exe.dev/AC-guest team baseline:

- pinned AgentsView version;
- per-architecture SHA-256 checksums;
- installation and version verification;
- `agentsview_version` in `~/iv-provision.lock`;
- source-daemon user service template;
- smoke and provisioning tests.

Installing the binary may be unconditional. Enabling the source daemon must be
conditional on tailnet reachability and local secret configuration.

### `iv-docs`

Owns the separate product/platform evaluation. Fleet dogfooding supplies
operational evidence; it does not silently promote AgentsView into the IV
Platform canon. Product adoption would require an ADR and updates to the
canonical Platform documents.

## Execution record — 2026-07-22

Phase 0 and the two Phase 1 canaries are live:

- `klundstedt-mini` runs AgentsView `v0.38.1` from the Homebrew cask under
  `com.kylelundstedt.agentsview`, bound only to its Tailscale IPv4 address on
  port `8080`. The tailnet URL presents the expected bearer-token login; an
  unauthenticated API request returns `401`.
- `iv-docs` (exe.dev, amd64) and `iv-sandbox` (Apple Container guest, arm64)
  run the pinned `v0.38.1` source service from `iv-image`. Both bind only their
  Tailscale IPv4 address, use unique per-host tokens, and reject unauthenticated
  remote-sync requests with `401`.
- Discovery is correct for data that exists: `iv-docs` exposes Claude and
  Shelley roots; `iv-sandbox` exposes Shelley. Neither canary currently has
  Codex session data to expose.
- The first coordinated sync produced 122 central sessions across three
  machines: 64 mini, 55 `iv-docs`, and 3 `iv-sandbox`. Exact sampled fidelity
  matched source and central counts: `iv-docs` 55 sessions / 3,296 messages /
  3,343 tool calls; `iv-sandbox` 3 / 18 / 9.
- The central archive was 67 MiB after the first canary sync. Persistent remote
  mirrors used 118 MiB. Observed idle source RSS was about 78 MiB on `iv-docs`
  and 62 MiB on `iv-sandbox`; central RSS was about 372 MiB after initial sync.
- `backup/agentsview-snapshot.sh` created a 67 MiB online SQLite backup with
  manifest, SHA-256, version, and successful `integrity_check`. The isolated
  restore check opened that snapshot through a clean AgentsView server and
  queried its API successfully.
- `com.kylelundstedt.agentsview-healthcheck` validates authenticated access,
  unauthenticated rejection, sync freshness, and snapshot freshness every five
  minutes. Its optional external healthchecks.io ping URL is not provisioned
  yet, so this is currently a local fail/log check rather than a dead-man alert.

One temporary bootstrap gap remains:

1. The implementation commits are deployed on the mini and canaries, but the
   newest dotfiles follow-ups and `iv-image` commit remain ahead of GitHub
   because the mini's GitHub CLI token is invalid. Re-authenticate GitHub CLI
   on the mini and push before treating provisioning as canonical.

## Execution record — 2026-07-22 (later)

### Token authority moved to 1Password

`op://Personal/AgentsView fleet tokens` (industryvault) is now the authority: a
Secure Note with one concealed field per consumer — `collector` for the mini's
UI/API token, then one field per source host. The collector field is mirrored to
login Keychain `agentsview:auth-token`, which `agentsview-service` already
preferred over its `config.toml` fallback, and the collector was restarted onto
that path. The earlier failure was specific to writing the login Keychain from a
remote SSH session; from an Aqua GUI session it succeeds. Inventory row and
rotation procedure: `secrets.md` + `provisioning/keys.manifest`.

### AgentsView Desktop cannot be used on the collector host

Tested against a scratch data directory; the production daemon was untouched.
The desktop app requires a **loopback-bound backend with bearer auth disabled**:

| Backend configuration                         | Desktop result                              |
| --------------------------------------------- | ------------------------------------------- |
| Tailnet-bound + `--require-auth` (production) | "backend status is unusable"                |
| Loopback + managed caddy + `--require-auth`   | daemon adopted; "interface did not respond" |
| Loopback, auth disabled                       | UI loads                                    |

The app's webview loads `http://127.0.0.1:PORT?desktop=1` with no Authorization
header, so `require_auth` locks out the app itself, not just remote clients.
There is no env var or setting pointing it at a remote collector — neither
binary exposes one. It is a local-archive viewer, not a client for a central
collector.

Consequence: on `klundstedt-mini` use the browser UI at
`http://klundstedt-mini.dojo-sun.ts.net:8080` with the collector token. Running
the desktop app there would mean dropping `--require-auth` and moving access
control to the transport (`tailscale serve`, already this host's pattern, or the
managed caddy's `100.64.0.0/10` ACL). That trades a per-request bearer token for
tailnet identity, so every tagged VM on the tailnet could read the whole
archive. Not worth it for a UI convenience; revisit only with a tailnet ACL
restricting port 8080.

Incidental findings: `--proxy caddy` requires `--public-url` (undocumented in
`--help`), and tailnet port 8443 is already taken by `tailscale serve`. Auth is
preserved end-to-end through the managed caddy — proxied unauthenticated API
requests return 401.

### Local Shelley source failed every sync since bootstrap

Every collector sync since 2026-07-21 19:45 logged
`sync error: listing shelley conversations: no such table: conversations`
(73 occurrences) and reported one failed source. Cause: auto-discovery created a
zero-byte `~/.config/shelley/shelley.db` on the mini, where Shelley is not
installed, then failed to read it forever. Removing the empty file fixed it; it
was not recreated on restart, and syncs are now clean.

The five-minute healthcheck did not catch this — it validates auth, archive
presence, sync _freshness_, and snapshot freshness, but not per-source sync
errors. A failing source is silent. Worth adding a per-source error assertion
before fleet rollout, when there are eight more sources to go wrong.

### Fleet inventory

Every active agent-capable tailnet host, checked 2026-07-22. All six exe.dev VMs
already carry the `agentsview-source.service` unit from `iv-image`; none is
enabled, so none of this history is collected:

| Host                  | Shelley db | Claude jsonl | Codex jsonl | Source daemon |
| --------------------- | ---------- | ------------ | ----------- | ------------- |
| `iv-docs`             | present    | 55 sessions  | none        | **active**    |
| `iv-sandbox`          | present    | none         | none        | **active**    |
| `kgl-thoughts`        | 49M        | 111          | 7           | inactive      |
| `iv-gitlake-examples` | 12M        | 4            | 3           | inactive      |
| `rss-feed`            | 9.9M       | 0            | 0           | inactive      |
| `iv-gitlake`          | 2.3M       | 0            | 0           | inactive      |
| `iv-home`             | 908K       | 1            | 0           | inactive      |
| `iv-ave-adapters`     | 172K       | 1            | 0           | inactive      |

`kgl-thoughts` is the largest uncollected host by an order of magnitude.
`llm-gateway` is excluded as a service-only appliance (no agent harness, SSH
refused). `klundstedt-mbp` could not be inventoried — Tailscale SSH is not
enabled on it — and remains scoped in only if agents run locally there; note
that running AgentsView Desktop on the mbp builds a _separate local_ archive and
does not feed the collector. Collecting the mbp requires a source daemon like
any other host.

## Rollout plan

### Phase 0 — prepare the collector

- [x] Pin the evaluated stable release (`v0.38.1`, rechecked 2026-07-22).
- [x] Install AgentsView on `klundstedt-mini`.
- [x] Create a local-only central data directory with restrictive permissions.
- [x] Configure central UI/API access over the tailnet only.
- [x] Move per-source token authority into 1Password/Keychain
      (`op://Personal/AgentsView fleet tokens`; collector mirrored to Keychain
      `agentsview:auth-token`, 2026-07-22).
- [x] Add consistent SQLite snapshot, Tigris inclusion, and restore procedure.
- [ ] Complete health monitoring by adding the external healthchecks.io ping.
      Local five-minute collector/sync/snapshot checks are active.
- [ ] Assert per-source sync success in the healthcheck. Freshness alone hid a
      local source that failed every sync for 73 consecutive runs.

### Phase 1 — two canaries

- [x] Enable a source daemon on one exe.dev VM (`iv-docs`).
- [x] Enable a source daemon on one Apple Container VM (`iv-sandbox`).
- [x] Verify Shelley, Claude, and Codex discovery where source data exists.
- [ ] Verify a newly created canary session appears centrally within ten minutes.
- [x] Compare sampled source and normalized sessions/messages/tool calls.
- [x] Verify unauthenticated remote-sync access is rejected.
- [ ] Complete resource measurement: idle CPU/RSS and archive/mirror size are
      recorded; capture steady-state sync traffic over a representative day.

### Phase 2 — fleet rollout

- [x] Add AgentsView to `provisioning/tools.manifest` and dotfiles installation.
- [ ] Push the pinned installation, source service, lock field, and tests in
      `iv-image` to GitHub (deployed commit is currently mini-local).
- [ ] Push/reconcile the newest dotfiles commits and canonical `iv-image`
      dotfiles pin after mini GitHub CLI re-authentication.
- [x] Inventory every active agent-capable tailnet host (2026-07-22; table in
      the execution record above).
- [ ] Roll out per-host credentials and stable collector names. Six inventoried
      VMs have the unit installed and inactive; start with `kgl-thoughts`.
- [ ] Decide whether `klundstedt-mbp` is in scope, and enable Tailscale SSH on
      it if so — it could not be inventoried without that.
- [ ] Confirm every active host has synced recently; do not rely on a static host
      list because the VM fleet is ephemeral.

### Phase 3 — destruction and restore test

- [ ] Choose a canary VM with no uncommitted work.
- [ ] Confirm its final sync and central session counts.
- [ ] Destroy or rebuild it.
- [ ] Confirm its historical sessions remain searchable centrally.
- [ ] Restore the central archive from Tigris into a clean environment.
- [ ] Confirm restored search, session lineage, and Recall evidence links.

### Phase 4 — Recall experiment

- [ ] Run Recall extraction in dry-run mode against a copy of the archive.
- [ ] Review/import a small set of non-sensitive candidate memories.
- [ ] Validate evidence, review state, supersession, and revocation behavior.
- [ ] Keep operational Recall access through AgentsView; use DuckDB direct reads
      only for analysis.
- [ ] Record whether Recall reduces the need to rediscover durable facts from
      transcripts.

## Acceptance criteria

Adopt AgentsView as permanent internal fleet infrastructure when:

- every active agent-capable host is centrally visible;
- new sessions normally arrive within ten minutes;
- host rebuild/deletion does not remove previously collected sessions;
- a Tigris-backed `sessions.db` snapshot restores successfully;
- source endpoints are tailnet-only and reject unauthenticated requests;
- no secrets are committed to dotfiles or `iv-image`;
- resource and storage costs are operationally negligible;
- normalized fidelity is adequate for search and continuity;
- the system is useful in real work for at least two weeks.

The pilot may succeed even if Recall is not yet production-worthy.

## Rollback

AgentsView is additive. Rollback is:

1. disable source and central services;
2. revoke per-host bearer tokens;
3. remove AgentsView from future provisioning;
4. retain or delete the central normalized archive according to the chosen
   policy;
5. leave Shelley, Claude, Codex, IV data stores, and IV ledgers untouched.

## Post-pilot decisions

The pilot should produce two independent decisions:

1. **Internal infrastructure:** keep or remove the unified fleet archive.
2. **IV Platform product:** whether to offer an IV-managed, client-isolated
   agent-history capability adjacent to ClientView and the IV data substrate.

A “keep” decision for internal infrastructure does not imply a “ship” decision
for clients.

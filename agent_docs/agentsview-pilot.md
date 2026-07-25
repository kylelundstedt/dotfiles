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

Both bootstrap gaps recorded here are closed as of 2026-07-22 (see the later
execution record): token authority moved to 1Password, and provisioning is
canonical on GitHub. The mini's GitHub CLI turned out to be authenticated and
working — `gh api user` and an authenticated push both succeed — so no
re-authentication was needed; `dotfiles` is pushed and `iv-image` `main` was
already in sync with its AgentsView source-daemon work.

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

### AgentsView Desktop cannot be used on any fleet host

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

This is not collector-specific. A source daemon runs the same invocation —
`serve --host "$TS_IP" --port 8080 --require-auth` against `~/.agentsview` — so
every one of the three refusal conditions holds on sources too. **The desktop
app and fleet participation are mutually exclusive on a given host**, whether
that host is the collector or a source. Its only remaining role is a machine
deliberately kept outside the fleet.

Consequence for the two Macs: on `klundstedt-mini`, use the browser UI at
`http://klundstedt-mini.dojo-sun.ts.net:8080` with the collector token. On
`klundstedt-mbp` the app works today only because no AgentsView daemon runs
there; enabling a source daemon to collect the mbp ends that. Skip the app on
both.

Making the app work on a fleet host would mean dropping `--require-auth` and
moving access control to the transport (`tailscale serve`, already this host's
pattern, or the managed caddy's `100.64.0.0/10` ACL). That trades a per-request
bearer token for tailnet identity, so every tagged VM on the tailnet could read
the whole archive. Not worth it for a UI convenience; revisit only with a
tailnet ACL restricting port 8080.

The browser UI is no downgrade — it is the same interface the app wraps in a
webview. Note each source daemon also serves that UI on its own tailnet address
(`iv-docs`, `iv-sandbox` both answer on `:8080`), gated by that host's own
token, but showing only that host's sessions. The fleet-wide view exists only on
the mini, and is reachable from any tailnet device.

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

### Fleet rollout completed

All six inventoried sources were enabled 2026-07-22 with unique tokens recorded
in 1Password and verified byte-identical across host, vault, and collector
config. Central archive: **335 sessions across 9 machines, 112 MB**
(`kgl-thoughts` 166, mini 65, `iv-docs` 57, `iv-gitlake-examples` 23,
`rss-feed` 10, `iv-gitlake` 5, `iv-home` 4, `iv-sandbox` 4,
`iv-ave-adapters` 1).

Fidelity spot-check on `kgl-thoughts`: source DB 110 claude + 7 codex + 49
shelley = 166, central 166. Note `/api/v1/stats` is windowed, not a total —
comparing it against central counts produces a false mismatch. Use the DB.

### Monitoring hardened

`agentsview-healthcheck` now also asserts zero failed sources
(`/api/v1/sync/status`) and probes every configured source for authenticated
200 / anonymous 401. External healthchecks.io check `agentsview` created
(period 300s, grace 600s), ping URL in Keychain `agentsview:healthcheck-url`,
row added to `provisioning/checks.manifest`, `check-monitoring.sh` clean.

Two lessons, both recorded in `monitoring.md`: a freshness check does not prove
the work happened, and printing the fan-out count in the success line
immediately exposed a config parser that silently covered 6 of 8 sources
because key order inside a `[[remote_hosts]]` block is not guaranteed.

### Phase 3 executed — destruction and restore

Built `av-canary` (exe.dev, joined tailnet, pinned v0.38.1 verified by
SHA-256), seeded one synthetic 4-message Claude session carrying a unique
marker, collected it, then destroyed the VM. Verified in order:

1. sessions survive the host's destruction and remain searchable centrally;
2. a **subsequent sync with the host gone does not purge them** — the collector
   reports the failure instead;
3. the new healthcheck correctly failed on the unreachable source, proving the
   assertion fires in production, not only in a synthetic test;
4. after removing the `[[remote_hosts]]` block, the check returned green and
   the retired host's sessions remained;
5. a fresh online snapshot restored into a clean data directory still contained
   the destroyed host's session, with its four messages in correct order.

Operational cost worth knowing: a dead configured source stalls each sync for
~90s on connection timeout. Retiring a VM must remove its `[[remote_hosts]]`
block in the same change — the healthcheck now enforces this by failing.

### Mirror cost — Zed was 74% of it

Baselining for the resource criterion found the mirrors at 761 MB against a
112 MB archive. The cause was not general fatness: `.claude/projects` and
`.config/shelley` mirror real session data and account for the other 190 MB.
It was Zed. A VM's `~/.local/share/zed` holds only the remote-server payload —
a ~210 MB node runtime, extensions, prettier — and never a threads database,
because Zed keeps agent threads on the client. The archive contains **zero Zed
sessions**, and no VM has a Zed threads DB at all.

|                | before       | after  |
| -------------- | ------------ | ------ |
| remote-mirrors | 761 MB       | 191 MB |
| of which Zed   | 571 MB (74%) | 0      |
| sessions       | 337          | 337    |

Fixed by pinning `ZED_DIR` at an empty directory on every source, verified one
host first, then fanned out; mirrors purged and re-synced with no session loss.
The durable fix is `iv-image` `2fee0ad`, which pins it in
`bin/agentsview-source-daemon` so rebuilt VMs inherit it, with tests covering
the default and an explicit override.

Two traps found on the way, both recorded because they cause false confidence:

- `/api/v1/stats` is windowed, so it under-reports against central totals.
- bash 3.2 on macOS — the authoring host — does **not** honour `set -e` for a
  failing bare `[[ ]]`, so `iv-image` tests run locally report a false green
  while aborting correctly on the bash 5.x VMs. Assertions there now use
  explicit failure.

### Growth and sync traffic measured (DuckDB mirror)

`agentsview duckdb push` mirrors the archive into
`~/.agentsview/mirror.duckdb` for analysis. It needs no server and no new
secrets, and the existing backup filter already excludes it (`- /.agentsview/**`)
— which is what the durable-backup section above anticipated for derived
indexes. Run it on demand; a watched daemon buys nothing here.

**Caveat: `duckdb push` flattens machine attribution.** Every session in the
mirror is stamped with the _pushing_ host, because the mirror is built for the
each-machine-pushes-its-own model where `machine` means pusher. Recover the true
origin from the session id prefix (`kgl-thoughts~…`); `AGENTSVIEW_DUCKDB_MACHINE`
is a single value and cannot preserve ten origins. Query the SQLite archive
directly for anything machine-level that matters.

**Storage growth is negligible and predictable.** Over the 14 days to
2026-07-22, measured by when work happened rather than when it was ingested:
136 sessions across 12 active days (**9.7/day**), 6,378 messages (**456/day**),
busiest day 38 sessions. At 113 MB for 337 sessions (~344 KB/session) that is
**~3.3 MB/day, ~100 MB/month, ~1.2 GB/year**, costing about $0.36/month to back
up after a full year.

What occupies the archive is worth knowing for any future retention rule: tool
call input+result content is **52.1 MB** against **8.2 MB** of message text and
2.1 MB of tool result events. Size tracks tool verbosity, roughly 6× the
conversation itself — so a size-motivated retention rule should target tool
payloads, not messages.

**Sync traffic is the part that scales badly.** Mirrors are whole-file with no
delta: touching a source `shelley.db` mtime with no content change refetched the
entire file. Per-round cost is therefore the sum of changed files, and Shelley
databases are the unit — `kgl-thoughts` 48.2 MB, `iv-docs` 29.0 MB,
`iv-gitlake-examples` 11.5 MB, `rss-feed` 9.9 MB, everything else under 2.5 MB.

| round                               | transferred |
| ----------------------------------- | ----------- |
| all hosts idle (measured)           | 0.2 MB      |
| every host active at once (ceiling) | 103 MB      |

At twelve rounds an hour, one continuously-active Shelley session on
`kgl-thoughts` would move ~578 MB/hour — the same 48 MB file re-fetched every
five minutes. Free in money (tailnet, and Tigris egress is free regardless) but
real bandwidth and disk writes, and invisible today only because those VMs are
mostly idle.

**Mitigation: `kgl-thoughts` and `iv-docs` moved to `interval = "15m"`**, which
cuts their worst case by two thirds. Every other host stays at 5m.

> **This creates a deliberate exception to an acceptance criterion.** "New
> sessions normally arrive within ten minutes" no longer holds for those two
> hosts, whose worst case is now ~15 minutes. Accepted because they are the
> traffic-heavy hosts and the least likely to need sub-15-minute freshness.
> Revisit if either becomes a host whose sessions are wanted promptly — the
> alternative is `10m`, which halves traffic while staying inside the criterion.
> Amend the criterion or the intervals before adoption; do not let them silently
> disagree.

### Collector outage + monitoring hardening (2026-07-25)

The mini collector was found DOWN for ~3 days. Proximate cause: a launchd
background agent that hits macOS TCC ("access data from other apps") during
session discovery BLOCKS and never binds its port. Discovery walked four agent
roots under `~/Library` — cowork, Zed, Warp, VS Code — none in the Claude Code +
Codex + Shelley scope. Fixed by pointing those four at an empty dir in
`agentsview-service` (`COWORK_DIR`/`ZED_DIR`/`WARP_DIR`/`VSCODE_COPILOT_DIR`), so
the collector never touches `~/Library`, never prompts, and is headless-safe. On
recovery the per-source healthcheck immediately caught a second casualty —
`iv-docs`'s source daemon had also died — which was restarted.

The real lesson was not the block but that **nobody was told**. The
`agentsview` healthchecks.io check had correct schedule and grace but **no
notification channel**, so its DOWN state alerted no one for three days; it was
found via the macOS popup. Two guardrails added:

- The `agentsview` check (and the identically-mute `personal-mcp: embeddings`)
  are wired to the email channel, and `check-monitoring.sh` now asserts every
  registered check routes somewhere — a right-config-no-channel check reads as
  covered while being silent.
- `agentsview-coverage` (drafted, see `monitoring.md`) makes fleet coverage
  fail-closed: an online Linux tailnet host that is neither a configured source
  nor an explicit appliance exclusion trips the check. This is the enforcement
  the "every agent-capable host is collected" criterion needs — the per-source
  probes only see hosts already in the config.

Retirement worked as designed through all this: `iv-sandbox` was deleted, its
`[[remote_hosts]]` block correctly gone, and its 4 sessions remain in the
archive — the Phase 3 guarantee holding in real operation, not a drill.

### Fleet inventory

Every active agent-capable tailnet host, checked 2026-07-22. All six exe.dev VMs
already carry the `agentsview-source.service` unit from `iv-image`; none is
enabled, so none of this history is collected:

| Host                  | Shelley db | Claude jsonl | Codex jsonl | Source daemon             |
| --------------------- | ---------- | ------------ | ----------- | ------------------------- |
| `iv-docs`             | present    | 55 sessions  | none        | **active**                |
| `iv-sandbox`          | —          | —            | —           | decommissioned 2026-07-22 |
| `kgl-thoughts`        | 49M        | 111          | 7           | inactive                  |
| `iv-gitlake-examples` | 12M        | 4            | 3           | inactive                  |
| `rss-feed`            | 9.9M       | 0            | 0           | inactive                  |
| `iv-gitlake`          | 2.3M       | 0            | 0           | inactive                  |
| `iv-home`             | 908K       | 1            | 0           | inactive                  |
| `iv-ave-adapters`     | 172K       | 1            | 0           | inactive                  |

`kgl-thoughts` is the largest uncollected host by an order of magnitude.
`llm-gateway` is excluded as a service-only appliance (no agent harness, SSH
refused). `klundstedt-mbp` could not be inventoried — Tailscale SSH is not
enabled on it — and remains scoped in only if agents run locally there; note
that running AgentsView Desktop on the mbp builds a _separate local_ archive and
does not feed the collector. Collecting the mbp requires a source daemon like
any other host.

## Execution record — 2026-07-24

### Collector down since 2026-07-22 — two independent faults

The mini's central collector stopped serving on 2026-07-22 15:56 and stayed
down until diagnosed on 2026-07-24. Two separate faults, both now understood.

**Fault 1 — idle-timeout shutdown is never restarted (recurrence trap).**
`agentsview serve` self-terminates on an idle timeout with exit code 0
(`idle timeout elapsed; shutting down daemon` in `/tmp/agentsview.log`). The
launchd job set `KeepAlive → SuccessfulExit = false`, so launchd treated the
clean exit as intentional and never restarted it — any idle period took the
collector down permanently. Fix: `KeepAlive` set to unconditional `<true/>` in
`launchd/Library/LaunchAgents/com.kylelundstedt.agentsview.plist`. Follow-up:
find and disable agentsview's daemon-mode idle shutdown so it stays one
long-lived process instead of restart-churning each idle period (no such flag
was visible in `serve --help`).

**Fault 2 — discovery deadlocks on an orphaned Warp file-provider container.**
Once stopped it could not restart: `serve` hangs deterministically at
"Discovering sessions", fully parked at 0 CPU, never binding 8080 (reproduced
under launchd and foreground). Bisected to one local input — empty `HOME`
starts in 23 ms, the real home hangs. Binary search over home → `Library` →
`Group Containers` → `2BBY89MBSN.dev.warp` (Warp's group container; matches the
`warp sync` syncer in `debug.log`). Even `ls`, `xattr`, `rename`, and `rm` on
that directory block forever though `stat` of the entry succeeds and Warp is not
running. `fileproviderctl dump` shows Warp is **not** a live File Provider
domain (only iCloud/OneDrive/Dropbox/Box/Photos are), so the container is
orphaned dataless placeholders left by a removed provider: every access routes
to a provider that no longer answers. Restarting `fileproviderd` did not heal
it; moving it aside hangs in `rename()`. Userland cannot clear it. Resolution:
reboot the mini (resets provider/kernel state), remove the orphaned
`2BBY89MBSN.dev.warp`, then restart the collector.

Ruled out with evidence: remote sources (all 7 answer 401, zero sync
connections held while hung), the DB (109 MB, `integrity_check: ok`, reads
instantly), auth, agentsview version (unchanged v0.38.1), and the Tigris backup
(ran 04:30 that day, integrity ok — it faithfully snapshotted a frozen DB, so
no new sessions were captured after 2026-07-22 until service was restored).

**Generalizable risk.** agentsview's local discovery walks broad roots
(`~/Library/Group Containers`, app databases) with no per-source ignore option
in `serve --help` or `config.toml`. A single wedged file-provider path anywhere
under a scanned root hangs the entire collector. Any fleet host with cloud-sync
placeholders (iCloud/OneDrive/Dropbox/Box) shares this exposure.

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
- [x] Verify a newly created session appears centrally within ten minutes: a
      marked session seeded on `iv-home` arrived in **39s** on the normal 5m
      schedule (favourable phase; structural worst case ~5m10s). Note the two
      hosts now at `interval = "15m"` are a deliberate exception — see the
      traffic section above.
- [x] Compare sampled source and normalized sessions/messages/tool calls.
- [x] Verify unauthenticated remote-sync access is rejected.
- [x] Complete resource measurement (2026-07-22). Idle CPU/RSS, archive/mirror
      size, storage growth (~3.3 MB/day) and per-round sync traffic (0.2 MB idle,
      103 MB ceiling) are all measured; the whole-file refetch behaviour is
      characterised rather than sampled over one day.

### Phase 2 — fleet rollout

- [x] Add AgentsView to `provisioning/tools.manifest` and dotfiles installation.
- [x] Push the pinned installation, source service, lock field, and tests in
      `iv-image` to GitHub (`main` in sync; `bin/agentsview-source-daemon`,
      `systemd/agentsview-source.service`, `tests/test-agentsview-source.sh`).
- [x] Push/reconcile the newest dotfiles commits (2026-07-22). The mini's
      GitHub CLI was already valid; no re-authentication was required.
- [x] Inventory every active agent-capable tailnet host (2026-07-22; table in
      the execution record above).
- [ ] Roll out per-host credentials and stable collector names. Six inventoried
      VMs have the unit installed and inactive; start with `kgl-thoughts`.
- [ ] Decide whether `klundstedt-mbp` is in scope, and enable Tailscale SSH on
      it if so — it could not be inventoried without that. Enabling a source
      daemon there also retires AgentsView Desktop on that machine; the two
      cannot coexist on one host.
- [ ] Confirm every active host has synced recently; do not rely on a static host
      list because the VM fleet is ephemeral.

### Phase 3 — destruction and restore test

Executed 2026-07-22 with a purpose-built throwaway (`av-canary`) rather than a
real service VM.

- [x] Choose a canary VM with no uncommitted work (created for the test).
- [x] Confirm its final sync and central session counts (1 session, 4 messages).
- [x] Destroy or rebuild it (`ssh exe.dev rm av-canary`).
- [x] Confirm its historical sessions remain searchable centrally.
- [x] Restore the central archive from Tigris into a clean environment.
- [x] Confirm restored search and session lineage. Recall evidence links remain
      untested — Recall itself is Phase 4.

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

### Adoption decision deferred to ~2026-08-04

Reviewed 2026-07-22 and held. Three criteria were open: most hosts not yet
collected, no destruction/restore test, and the system had been live under a
day against a two-week bar. The day's two silent defects — 73 consecutive
failed syncs invisible to monitoring, and a client unusable on any fleet host —
argued for letting the clock run rather than against the tool.

Two structural questions must be answered before the label changes. Neither
blocks day-to-day use; both get expensive to decide late.

1. **Retention mechanism.** The data policy above says what the archive is, not
   how it is bounded. There is no retention rule, only the manual
   `agentsview prune`. The archive was 70 MB from three machines on day one,
   grows with every host added, holds prompts/tool results/shell commands, and
   rides the nightly Tigris backup. Decide a rule — by age, by host lifetime,
   or by explicit prune cadence — while the number is small enough that
   deleting is not frightening.

   **This is not a cost decision.** Tigris pricing was checked 2026-07-22: the
   nightly full snapshot into Infrequent Access costs ≈ $0.30 per GB of archive
   per month (30 billed copies, since IA has a 30-day minimum storage duration
   and rclone cannot delta a SQLite file), which is about **$0.03/month** at the
   current 102 MB. Egress is free, so a full restore costs ~$0.001 in retrieval
   fees. An earlier note here framed backup amplification as a compounding
   pressure; the mechanism is real but the magnitude is not, and cadence — not
   archive retention — is the lever if a snapshot ever gets large. Table and
   rule of thumb: `tigris-backup-runbook.md`. Decide retention on what is worth
   keeping and how sensitive it is, not on storage spend.

2. **Token fan-out.** `secrets.md` still calls the mode-`0600` `source.env`
   pattern a temporary pilot delivery mechanism. Permanent infrastructure needs
   a real provisioning path from `op://Personal/AgentsView fleet tokens` to each
   host, rather than hand-placement repeated per host. `iv-image` already owns
   the unit; the token step is the manual remainder.

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

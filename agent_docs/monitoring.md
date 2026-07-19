# Monitoring — healthchecks.io registry

Every unattended job pings a healthchecks.io check (dead-man's-switch). The
ping URLs live in the login Keychain (no secrets in git); the check
_schedules_ live in the healthchecks.io dashboard — which means they can
silently diverge from the launchd schedules in git.

**The rule: a job reschedule is not done until its check schedule moves in
the same change.** This bit hard on 2026-07-11..13: the U9 reschedule moved
web-archive-refresh to 03:30 while its check still expected `0 4 * * *` —
the early ping brought it UP, the unmet 04:00 slot took it DOWN at 07:00,
every single day.

Grace sizing rules (each learned the hard way):

- Grace must exceed the job's **run duration** when the job pings `/start`.
- Long-running phases need their own duration limit below the check's grace;
  otherwise a live but pathologically slow process can remain STARTED until the
  check goes DOWN without ever reporting `/fail`.
- A check's alert window must exceed the job's **cadence** when runs can
  skip (the monthly key-expiry check warns at 35d, not 14d).
- Staleness-skipping jobs must **ping success on skip** (sync-repos,
  tigris-backup do) or a manual run phase-shifts the nightly into a silent
  skip and the check starves.
- **Don't kickstart jobs concurrently that the schedule serializes.**
  web-archive-refresh (writes web-archive.duckdb) and rebuild-hub (attaches
  it read-only) conflict on the DuckDB lock — the 03:30/04:00 stagger is
  load-bearing. Kickstarting both at once (2026-07-13) failed the web job
  and pinged /fail. One at a time, in schedule order.
- **A liveness probe must cover the service's dependencies, not just its
  port.** The mcp-server check counted any HTTP response as healthy while
  LM Studio's embedding endpoint (localhost:1234) was down for 2.5 days —
  semantic_search dead, nightly embed steps silently skipping ("best-effort"),
  every check green. Best-effort degradation needs its own check
  (`personal-mcp: embeddings`) or it is invisible.
- **Don't edit a running shell script in place.** Bash can read script input
  incrementally; replacing the file while a long-running command is active can
  make the existing process resume at an invalid offset and fail to parse.

## Registry

The registry is data, not prose: **`provisioning/checks.manifest`** pairs
every check with its expected schedule, timezone, and grace.
`provisioning/check-monitoring.sh` verifies it against the live API (runs in
`test-install.sh provisioning`; needs Keychain `healthchecks:api-key`,
mini-only, self-skips elsewhere). Ping URLs stay in the login Keychain, one
per job (`<job>:healthcheck-url` / `personal-mcp:<job>-healthcheck-url`).

Shared job semantics (staleness skip pings success, lastrun only on clean
runs, locks, dated logs) live in `backup/_lib.sh`, sourced by
tigris-backup.sh, sync-repos.sh, and restore-drill.sh — the rules above are
library properties, not per-script conventions.

## Scope: this registry covers the klundstedt-mini project only

The manifest + drift check govern the checks in the **klundstedt-mini**
healthchecks.io project — the jobs owned by this repo and personal-mcp.
Monitoring boundaries follow repo/VM boundaries (decided 2026-07-14): a
service with its own repo on its own VM owns its own check in its own
project, configured and documented there. Known out-of-registry monitoring:

- **rss-feed** (`kylelundstedt/rss-feed`, rss-feed VM) — a systemd timer runs
  `healthcheck.sh` every ~16 min, validates every generated feed, and pings a
  check in a separate healthchecks.io project (URL in
  `~/.config/rss-feed/healthchecks.env` on the VM).

`check-monitoring.sh`'s reverse pass ("every live check must be in the
manifest") only sees the mini project, so out-of-registry checks never
false-positive here — but their schedule/grace drift is each repo's own
responsibility.

## Incident notes

- 2026-07-04..09: sync-repos + tigris-backup flapping — three stacked causes
  (gitconfig SSH rewrite in launchd, lastrun written on failure, iCloud
  .Trash eviction). Fixed `ab1d21e`, `53040c6`, `d2242b7`.
- 2026-07-11..13: daily web-archive-refresh + rebuild-hub flapping — U9
  reschedule not propagated to check schedules; rebuild-hub check also
  created as `* 4 * * *` (every minute of the 4 o'clock hour) instead of
  `0 4 * * *`. tigris-backup separately red on evicted iCloud app-container
  files (`iCloud~*` now excluded from the backup wholesale).
- 2026-07-14..17: LM Studio's API server didn't come back after a reboot
  (the app relaunches at login, its server toggle doesn't) — semantic_search
  down 2.5 days, zero alerts. Fix: `healthcheck-mcp.sh` now probes
  localhost:1234 every 15 min, self-heals via `lms server start`, and pings
  the new `personal-mcp: embeddings` check (period 900s, grace 1800s).
- 2026-07-19: tigris-backup's Photos sync spent 8h+ checking roughly 100k
  objects because S3 modification-time comparisons require a HEAD per object
  and Tigris responses were abnormally slow. The transfer itself had finished;
  no 429/503/retry evidence identified the provider-side cause. Split the job
  into a daily server-modtime sync (no per-object HEAD) and a separately
  monitored weekly exact reconciliation. Both have run-wide deadlines below
  their check grace. Also fixed the osxphotos completeness gate, which had
  parsed status text instead of the final numeric count.

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
- **A dead-man's switch wired to no channel is decoration.** The `agentsview`
  check (and `personal-mcp: embeddings`) had correct schedule and grace but no
  notification channel — so when the collector sat DOWN for ~3 days (2026-07-25)
  the check flipped to DOWN and told no one; it was found via an unrelated macOS
  popup. `check-monitoring.sh` now asserts every registered check routes to at
  least one channel. Right config with nowhere to send is worse than no check,
  because it reads as covered.
- **A freshness check does not prove the work happened.** The AgentsView
  collector finished every sync on schedule for 73 consecutive runs while one
  source failed every time (2026-07-22) — the check asserted "a sync completed
  recently", never "every source contributed". Same family as the mcp-server
  lesson above: assert the dependency, not the wrapper. The check now asserts
  zero failed sources and probes each configured source itself.
- **Report the fan-out count in the success line.** Printing "8 source(s)
  reachable" immediately exposed a config parser that silently covered only 6
  of 8 — a check that quietly skips half its targets still reports OK.
- **A subprocess's own deadline flag is not a wall-clock guarantee.** rclone's
  `--max-duration` bounds its transfer phase, not a wedge in the post-transfer
  finalize phase — on 2026-07-25 rclone hit 100% then hung there for 8h,
  ignoring a 2h `--max-duration`, with nothing external to kill it. Any
  wedge-prone subprocess (rclone, a Go binary reading a stuck path) must run
  under an external wall-clock cap (`run_bounded`/`pm_run_bounded` — macOS has
  no `timeout(1)`) so a hang becomes a bounded rc=124 failure that pings /fail,
  instead of running past the check grace and starving it.

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

### AgentsView fleet coverage (`agentsview-coverage`, live 2026-07-25)

A **fail-closed** coverage check: every online Linux tailnet node must be either
a configured AgentsView source or listed in
`provisioning/agentsview-coverage-exclude.txt` (currently empty — the last
appliance, llm-gateway, was decommissioned). A new agent-capable VM collected by
neither trips it — the gap that left six VMs silently uncollected (2026-07-22)
and that the per-source probes can't catch, since they only see hosts already in
config. `com.kylelundstedt.agentsview-coverage` runs it hourly and pings the
`agentsview-coverage` check (period 3600s, grace 7200s, Keychain
`agentsview-coverage:healthcheck-url`). Run `agentsview-coverage --dry-run` to
classify without pinging.

## Scope: this registry covers the klundstedt-mini project only

The manifest + drift check govern the checks in the **klundstedt-mini**
healthchecks.io project — the jobs owned by this repo and personal-mcp.
Monitoring boundaries follow repo/VM boundaries (decided 2026-07-14): a
service with its own repo on its own VM owns its own check in its own
project, configured and documented there. Known out-of-registry monitoring:

- **rss-feed** (`kylelundstedt/rss-feed`, rss-feed VM) — a systemd timer runs
  `healthcheck.sh` every ~16 min, validates every generated feed, and pings a
  check in a separate healthchecks.io project (URL in
  `~/.config/rss-feed/healthchecks.env` on the VM). Rebuilt 2026-07-28 on the
  exeslim deployment lane ([vm-disk-weight.md](vm-disk-weight.md)); the timer,
  the ping URL, and the check are unchanged. The validation no longer uses
  `python3` (absent from that image) — it asserts an RSS/Atom root and a
  non-zero item count in pure shell, with `xmllint` supplying well-formedness.
  The VM is **no longer an AgentsView source** (no agent harness, not on the
  tailnet): its `[[remote_hosts]]` block was removed from the collector config
  and it is listed in `provisioning/agentsview-coverage-exclude.txt`, so
  `agentsview-coverage` reports it as an excused host that is not online.

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
- 2026-07-21: the daily backup stalled after home sync because the Photos gate's
  ephemeral `uvx` runtime waited on a macOS removable-volume permission modal.
  The gate was outside the rclone-only deadline and treated every execution
  error as success. Replaced uvx with a persistent Python 3.12 osxphotos tool,
  bounded the entire process group, and made all gate failures skip Photos but
  fail the overall run after the unrelated archive sources continue.
- 2026-07-25: tigris-backup AND personal-mcp:msgvault-sync both DOWN — two
  unrelated hangs the same night, both wedged 8–9.5h. (a) tigris-backup: rclone
  finished the home transfer (100%) then hung in its finalize phase, ignoring
  its own 2h `--max-duration`; nothing external bounded it. (b) msgvault-sync:
  the live Messages store wedged — `~/Library/Messages` readdir hung
  indefinitely (chat.db intact at ~218 MB; a stuck-vnode state held by the
  Messages processes, not corruption) — so `import-imessage` blocked before
  its first log line and the sync never reached its success ping. Ruled out:
  system sleep (machine stayed awake, UPS on AC), disk (SMART Verified, no
  faults). Fixes: added `run_bounded`/`pm_run_bounded` (bash wall-clock cap;
  macOS has no `timeout(1)`) as a backstop around rclone (`remaining+180s`) and
  import-imessage (600s); a cap-fired hang now returns rc=124 → pings /fail
  instead of starving the check. Cleared the live wedge by killing the Messages
  subsystem (imagent/IMDPersistenceAgent/BlastDoor respawn; readdir recovered
  without a reboot). See the "subprocess's own deadline flag" rule above.
- 2026-07-25: agentsview flapped (down 13:52, up 13:57) — the healthcheck
  crashed on `datetime.fromisoformat()`. Under launchd, `bash -l -c` resolves
  `python3` to `/usr/bin/python3` (3.9), NOT Homebrew 3.14, and 3.9 rejects
  fromisoformat fractions that aren't 3 or 6 digits. Postgres strips trailing
  zeros, so `last_sync_finished_at` intermittently serialized as `.57173`
  (5 digits) → crash → /fail. Fix: strip sub-second precision before parsing
  (age is integer seconds), so it's python-version-proof. Lesson: launchd
  jobs get the system python, not your shell's — don't rely on a newer
  interpreter's leniency.

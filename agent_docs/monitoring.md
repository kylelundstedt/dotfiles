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
- **A log classifier is a guess about another tool's output format — replay it
  before trusting it.** `tigris-backup`'s benign-change branch keyed on
  `ERROR : .*Failed to (copy|update)` and then re-grepped that subset for
  `corrupted on transfer`. rclone only writes the `Failed to copy:` wrapper when
  the copy call itself errors; a post-transfer size mismatch is logged bare. The
  two patterns were **disjoint**, so the branch matched 0 lines on every run for
  the five days it existed while printing `benign=0 of 0` — a suppression rule
  that suppressed nothing, and read as working. One `grep -c` over an existing
  log would have caught it. Any new log-parsing rule must be replayed against
  several days of real logs, and the counts it reports must be non-zero
  somewhere before the rule is believed.
- **`check-monitoring.sh` asserts configuration, not arrival.** It verifies
  schedule, timezone, grace and channel against the manifest — and passed
  `agentsview-retention` every run from 2026-07-28 to 2026-08-26 while that
  check sat at `n_pings=0`, having never received a single ping. The URL was
  right, the Keychain item was right, the manifest row was right; the _call_ was
  malformed (`job_hc --data-raw "…"` puts `--data-raw` in the URL path, and
  `job_hc` swallows the 404 with `|| true`). Same family as the "wired to no
  channel" lesson above, one level deeper: right config with nothing arriving is
  worse than no check, because the drift check vouches for it.
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

A **fail-closed** coverage check: every running exe.dev VM **and** every online
Linux tailnet node must be either a configured AgentsView source or listed in
`provisioning/agentsview-coverage-exclude.txt` (currently: `rss-feed`, the
deployment-lane VM; `ai`, a Tailscale Aperture gateway appliance; and
`quack-client`/`quack-server`, experiment VMs — the last three excused
2026-08-26). Since 2026-07-28 it enumerates the exe.dev inventory as
well as tailnet peers — enumerating peers alone left the guarantee open exactly
where coverage was most likely missing, because a VM nobody enrolled is not a
peer. That change immediately surfaced three uncovered VMs, one created the
same day. A new agent-capable VM collected by
neither trips it — the gap that left six VMs silently uncollected (2026-07-22)
and that the per-source probes can't catch, since they only see hosts already in
config. `com.kylelundstedt.agentsview-coverage` runs it hourly and pings the
`agentsview-coverage` check (period 3600s, grace 7200s, Keychain
`agentsview-coverage:healthcheck-url`). Run `agentsview-coverage --dry-run` to
classify without pinging.

### Entire checkpoint durability (`entire-push-check`, live 2026-07-28)

A **fail-closed** durability check: no repo on any fleet host may hold commits
on `refs/heads/entire/**` that exist on no remote. Entire records the "why" of
agent work on that ref and ships it via a `pre-push` hook, so the record is
durable **only once pushed** — an unpushed checkpoint dies with the host and
nothing else notices. Found for real on 2026-07-28 (`iv-foundry-stage2` held 5
on `fannie-sflpd`).

**The check itself lives in `iv-provision` (`bin/entire-push-check`) since
2026-08-24 (#22).** What stays here is the personal scheduling concern: the
launchd job, the Keychain ping URL and the log. `maint/.local/bin/entire-push-check`
is a thin wrapper that resolves the real check by naming candidate checkout
paths and **fails loudly** (pinging `/fail`) if none is found — a wrapper that
silently no-opped after a checkout moved would report green forever.

`com.kylelundstedt.entire-push-check` runs it **daily**, not hourly: it SSHes
to every fleet host and reaches exe.dev-only hosts over the rate-limited
`*.exe.xyz` path, and an unpushed checkpoint is a slow-moving condition.
Keychain `entire-push-check:healthcheck-url`; exclusions moved with the check to
**`iv-provision/provisioning/entire-push-exclude.txt`** and are resolved relative
to the script there (one entry: `iv-foundry-stage2:worktrees/entire-agent-shelley-m4`,
excused 2026-08-26 — a bootstrap ref that cannot be pushed because that VM's
integration for the repo is read-only). `--dry-run` reports without pinging.

Host discovery comes from `ssh exe.dev ls --json`, the same authoritative
inventory `agentsview-coverage` now uses — **not** the tailnet, which cannot
see a VM that never joined.

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
  and it is listed in `provisioning/agentsview-coverage-exclude.txt`. Coverage
  now reports it as `excused` and, via the inventory pass, as the one
  "running exe.dev VM but not an online tailnet peer" — which is exactly the
  shape a deployment-lane VM should have.

(`entire-push-check` moved into the registry proper — see below.)

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
- 2026-08-26: four checks DOWN at once, four unrelated causes, **zero config
  drift** — `check-monitoring.sh` reported every schedule, grace and channel
  correct throughout. (a) `tigris-backup`/`-reconcile`: the benign-change
  classifier added five days earlier matched nothing (see the log-classifier
  rule above), so ~350 benign Photos-index `sizes differ` errors failed the
  phase every night. (b) The same run's real failure was 90 EDEADLK reads on
  `57T9237FN3~net~whatsapp~WhatsApp` — the 2026-07-11 `iCloud~*` exclusion never
  matched it, because a container declared via an **App Group** is named
  `<TEAMID>~vendor~app`, not `iCloud~…`. Scoped the new rule to that one
  container: it is the only one that has ever errored, and a blanket `<TEAMID>~`
  rule would also have dropped Ulysses, Readdle and FoldingText **documents**
  from the backup. (c) `agentsview-retention` had never pinged at all (see the
  arrival rule above). (d) `agentsview-coverage` and `entire-push-check` both
  starved on `ssh exe.dev ls --json` — coverage failed that way **578 times**
  between 2026-07-28, when the inventory pass landed, and 2026-08-26, i.e.
  essentially every hourly run for a month, with two successes. It recovered on
  its own.
  **The expensive part was (d) masking the rest**: a month of alerts on the
  _probe_ hid the gap the check exists to find. When the inventory finally
  answered, coverage immediately named four uncovered agent-capable hosts
  (`ai`, `iv-cli`, `quack-client`, `quack-server`) and `entire-push-check` named
  two unpushed Entire checkpoints. A fail-closed check whose dependency fails
  closed _first_ reports the dependency forever and the finding never. Suspect
  the hourly cadence is self-inflicting the exe.dev SYN-drop lockout documented
  in `AGENTS.md` — back the inventory call off or cache it.
  Resolution: `iv-cli` enrolled as a real source; `quack-*` excused as
  experiment VMs; `ai` excused as a Tailscale Aperture gateway appliance; the
  `ave-adapters` checkpoint pushed; the `entire-agent-shelley` one excused,
  since `iv-foundry-stage2`'s integration for that repo is **read-only** (403)
  and the ref was a bootstrap commit carrying no transcript.

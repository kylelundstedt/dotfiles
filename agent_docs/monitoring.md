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

- Grace must exceed the job's **run duration** when the job pings `/start`
  (tigris-backup runs ~2.5h).
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

## Registry (project: klundstedt-mini, TZ America/Los_Angeles)

| Check                               | Job (repo)                                  | Job schedule         | Check schedule  | Grace | Keychain ping-URL item                         |
| ----------------------------------- | ------------------------------------------- | -------------------- | --------------- | ----- | ---------------------------------------------- |
| `sync-repos`                        | dotfiles `sync-repos.sh`                    | 00:00 + 12h wake     | `0 0 * * *`     | ~19h  | `sync-repos:healthcheck-url`                   |
| `tigris-backup`                     | dotfiles `backup/tigris-backup.sh`          | 04:30                | `30 4 * * *`    | 8h    | `tigris-backup:healthcheck-url`                |
| `personal-mcp: msgvault`            | personal-mcp `msgvault-sync.sh`             | 03:00                | `0 3 * * *`     | —     | `personal-mcp:msgvault-healthcheck-url`        |
| `personal-mcp: web-archive-refresh` | personal-mcp `web-archive-refresh.sh`       | 03:30                | `30 3 * * *`    | 3h    | `personal-mcp:web-healthcheck-url`             |
| `personal-mcp: rebuild-hub`         | personal-mcp `hub/rebuild-hub.sh`           | 04:00                | `0 4 * * *`     | 2h    | `personal-mcp:hub-healthcheck-url`             |
| `personal-mcp: mcp-server`          | personal-mcp `healthcheck-mcp.sh` (probe)   | every 15 min         | period 15m      | —     | `personal-mcp:mcp-server-healthcheck-url`      |
| `check-key-expiry`                  | dotfiles `provisioning/check-key-expiry.sh` | monthly (1st, 10:00) | not created yet | —     | `key-expiry:healthcheck-url` (not provisioned) |

Grace values marked — are unverified (set in the dashboard; not readable
without an API key). If a read-write API key is ever stored
(`healthchecks:api-key` in the Keychain), check schedules become
agent-manageable and a drift check against this table becomes possible
(natural U10+ follow-up).

## Incident notes

- 2026-07-04..09: sync-repos + tigris-backup flapping — three stacked causes
  (gitconfig SSH rewrite in launchd, lastrun written on failure, iCloud
  .Trash eviction). Fixed `ab1d21e`, `53040c6`, `d2242b7`.
- 2026-07-11..13: daily web-archive-refresh + rebuild-hub flapping — U9
  reschedule not propagated to check schedules; rebuild-hub check also
  created as `* 4 * * *` (every minute of the 4 o'clock hour) instead of
  `0 4 * * *`. tigris-backup separately red on evicted iCloud app-container
  files (`iCloud~*` now excluded from the backup wholesale).

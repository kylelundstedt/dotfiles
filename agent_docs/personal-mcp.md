# Personal MCP Server (`hub-mcp`)

A unified search layer over Kyle's personal archives — email/iMessage, calendar, and
saved web/Reader content — exposed to AI agents as a single MCP server. Runs only on
**`klundstedt-mini`** (the always-on Mac mini); every script and LaunchAgent is
capability-guarded, so deploying them everywhere via stow is a no-op on machines that
lack the archives.

The `personal-mcp/` package in this repo holds the ingest scripts and the server
launcher. The actual data and the server code live outside the repo under
`~/archives/` (not in git — see the [Tigris backup runbook](tigris-backup-runbook.md)
for how it's backed up).

## Data layout (`~/archives/`, on klundstedt-mini)

| Path                               | Contents                                                        |
| ---------------------------------- | --------------------------------------------------------------- |
| `email/`                           | msgvault store for both Gmail accounts (`MSGVAULT_HOME`)        |
| `calendar/sources/*.ics`           | Google Takeout calendar exports (input)                         |
| `calendar/calendar-archive.duckdb` | Built calendar archive, one row per event                       |
| `web/`                             | Readwise Reader archive + `web-archive.duckdb` (FTS + vectors)  |
| `hub/build_hub.sql`                | Query that unions email + calendar + web into one searchable DB |
| `hub/hub.duckdb`                   | Unified search hub the MCP server reads                         |
| `hub/mcp/server.py`                | The MCP server (FastMCP/uv project)                             |

## Ingest scripts (`personal-mcp/`)

All are idempotent, take a `mkdir` lock to prevent overlap, and no-op when their
prerequisites (binary, archive dir) are absent. Safe to run by hand.

| Script                   | Schedule                 | What it does                                                                                                                      |
| ------------------------ | ------------------------ | --------------------------------------------------------------------------------------------------------------------------------- |
| `msgvault-sync.sh`       | LaunchAgent, daily 03:00 | `msgvault sync` both Gmail accounts (falls back to `sync-full`), rebuild the analytics cache, then `msgvault embeddings build`.   |
| `web-archive-refresh.sh` | LaunchAgent, daily 04:00 | Pull all Reader docs, rebuild the documents table + FTS index, embed (if available), then **rebuild the unified hub** at the end. |
| `calendar-refresh.sh`    | Manual (no LaunchAgent)  | Rebuild `calendar-archive.duckdb` from the `.ics` files in `calendar/sources/`. Run after dropping fresh Takeout exports.         |
| `personal-mcp.sh`        | LaunchAgent, KeepAlive   | Launch the MCP server (`uv run python server.py`) from `~/archives/hub/mcp`, bound to `127.0.0.1:8765`.                           |

### Embeddings (semantic search) are best-effort

Both `msgvault-sync.sh` and `web-archive-refresh.sh` build vector embeddings for
semantic/hybrid search using a local [LM Studio](https://lmstudio.ai/) endpoint
(`http://localhost:1234`, model `text-embedding-nomic-embed-text-v1.5@q8_0`). If
LM Studio isn't serving, the embedding step is skipped with a warning — FTS still
updates, and the next run drains the pending messages/docs (incremental builds are
idempotent). A missing endpoint never fails the sync.

### Refresh ordering

msgvault (03:00) runs before web-archive-refresh (04:00), so when the latter rebuilds
`hub.duckdb` at the end of its run, email is already fresh. The hub is built to
`hub.duckdb.tmp` and swapped in with an atomic `mv`, so the read-only server never
reads a half-written database. Calendar is refreshed manually, so its slice of the hub
is only as current as the last `calendar-refresh.sh` run.

## The server

`personal-mcp.sh` runs `~/archives/hub/mcp/server.py`, which serves the unified hub
over HTTP at `127.0.0.1:8765/mcp`. It's kept alive by a LaunchAgent
(`RunAtLoad` + `KeepAlive` on crash). To reach it from other tailnet machines it's
exposed **tailnet-only over HTTPS** with `tailscale serve` at
`https://<node>.<tailnet>.ts.net/mcp` — never on the public internet.

Because it's a local HTTP MCP server, it is registered with `claude mcp add` directly
rather than provisioned by `install.sh` (which only handles the four remote servers).
Verify it's connected with:

```bash
claude mcp list | grep hub-mcp        # -> http://127.0.0.1:8765/mcp (HTTP) - ✔ Connected
```

## LaunchAgents

The plists live in the `launchd/` stow package
(`launchd/Library/LaunchAgents/com.kylelundstedt.{msgvault-sync,web-archive-refresh,personal-mcp}.plist`)
and stow-symlink into `~/Library/LaunchAgents/`. All three log to `/tmp/<label>.log`.
The same package also carries unrelated jobs (`sync-repos`, `tigris-backup`) — those
are not part of personal-mcp.

```bash
# Reload after editing a plist
launchctl unload ~/Library/LaunchAgents/com.kylelundstedt.personal-mcp.plist
launchctl load   ~/Library/LaunchAgents/com.kylelundstedt.personal-mcp.plist

# Run an ingest job now instead of waiting for its schedule
~/dotfiles/personal-mcp/msgvault-sync.sh

# Tail a log
tail -f /tmp/personal-mcp.log
```

## Troubleshooting

- **`hub-mcp` not connected** — check the server is up (`tail /tmp/personal-mcp.log`);
  it no-ops if `~/archives/hub/mcp` is missing or `uv` isn't installed.
- **Stale search results** — confirm the relevant ingest job ran (`/tmp/<label>.log`);
  for calendar, remember it's manual.
- **Semantic search returns nothing** — the embedding model isn't loaded in LM Studio;
  FTS still works. Load `text-embedding-nomic-embed-text-v1.5@q8_0` and re-run the
  ingest job.
- **msgvault full sync fails** — the OAuth token likely needs interactive re-auth;
  run `msgvault sync <account>` by hand to complete the browser flow.

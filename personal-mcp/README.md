# personal-mcp — local archives + unified search (klundstedt-mini)

Documents the data in `~/archives/` (consolidated local copies of email + calendar + saved web
reading + message attachments, plus the speaking/media history) and the code that builds and serves
it, which lives in this repo dir (`personal-mcp/`).

**The archive _data_ is private — this machine only, not in git** — but it's backed up nightly to
Tigris (client-side encrypted, multi-region; see [Backup](#backup)). **This document** is versioned
here at `personal-mcp/README.md` and symlinked to `~/archives/README.md` so it stays readable in place.

## Layout

- `email/` — msgvault archive: both Gmail accounts + career mboxes (1997–). This is
  msgvault's home dir; reach it via `MSGVAULT_HOME` (see below).
- `calendar/`
  - `calendar-archive.duckdb` — unified calendar, ~42k events (19.7k distinct UIDs), 2000–2027,
    plus an `embeddings` table (one nomic-768 vector per UID) for semantic search.
  - `sources/` — the `.ics` it's built from (Takeout exports + historical backups), plus
    `calendar-embeddings.jsonl` (the vector cache, survives event rebuilds).
    Build code is in the repo at `~/dotfiles/personal-mcp/calendar-archive/`
    (`calendar_archive.py`, `embed_calendar.py`, `build_calendar_embeddings.sql`).
- `web/` — Readwise Reader archive: saved articles, blog posts, tweets, web pages.
  - `web-archive.duckdb` — `documents` table + full-text (BM25) index + `embeddings` (vector) table, ~1,140 docs.
  - `sources/reader-documents.jsonl` — raw API pull (source of record); `sources/embeddings.jsonl` — vectors.
  - **Build code is versioned in the repo** at `~/dotfiles/personal-mcp/web/`: `pull_reader.py` /
    `embed_reader.py` (pull + embed), `build_documents.sql` / `build_embeddings.sql`, `search.sh`
    (keyword), `semantic.sh` (meaning). They read this data dir by default; override with `WEB_ARCHIVE_DIR`.
- `messages/` — iMessage/SMS attachments recovered from an encrypted iPhone backup.
  - `messages.duckdb` — `message_attachments` table (file metadata + owning-message link).
  - `build_index.py` (in repo: `~/dotfiles/personal-mcp/messages/`) — decrypt-and-index pipeline. The attachment **bytes** live in a
    content-addressed store on the external drive (`/Volumes/OWC8TB/messages-store/`),
    not here — only the index is on internal disk. (Message _text_ is in `email/`/msgvault.)
- `hub/` — unified search across all the archives.
  - `hub.duckdb` — one `items` table (email + iMessage/SMS + calendar + web + message
    attachments, normalized) with one BM25 index.
  - `build_hub.sql` (rebuild) and `search.sh "query" [limit] [source]` — both in repo at
    `~/dotfiles/personal-mcp/hub/` (search.sh reads `~/archives/hub` by default; override `HUB_ARCHIVE_DIR`).
- `speaking-engagements.md` — curated speaking & TV/media history (derived from the two archives).

## Update cadence

- **Work email** — nightly (3am), fully automatic (LaunchAgent).
- **Personal email** — also nightly, _but_ the OAuth token expires ~weekly (Testing-mode app),
  so it silently goes stale until the manual browser re-auth (see below). Work is unaffected.
- **Calendar** — **does NOT auto-update.** Manual rebuild only, whenever you re-export Takeout.
  Historical data never changes; only recent events drift between exports.
- **Web (Reader)** — nightly 4am via LaunchAgent (incremental pull + rebuild + embed). Independent
  of Reader's cloud; you keep saving to Reader as usual.

## Email (msgvault)

`MSGVAULT_HOME=~/archives/email` is set in `~/.profile`, so all **new** shells and the
LaunchAgent pick it up.

> **Gotcha:** a shell opened _before_ that change won't have it — msgvault then falls back to
> the default `~/.msgvault` and silently creates a stray empty dir. Always use a fresh shell, or
> `export MSGVAULT_HOME=~/archives/email`. Check with `echo $MSGVAULT_HOME`.

- **Work account auto-syncs** daily 3am via LaunchAgent `com.kylelundstedt.msgvault-sync`
  (the `schedule = "0 2 * * *"` in `config.toml` is vestigial — launchd drives the sync, not
  msgvault's internal scheduler)
  (`~/dotfiles/personal-mcp/msgvault-sync.sh`). Log: `/tmp/msgvault-sync.log`.
- **Personal account = manual re-auth ~weekly** (OAuth app stays in Testing → 7-day token; going
  to Production needs Google verification, not worth it for one user). `--headless` does **not**
  work for Gmail (Google's device flow blocks Gmail scopes). To re-auth: run
  `msgvault add-account kylelundstedt@gmail.com` **on a machine with a browser** (e.g. screen-share
  into this mini's desktop), consent, and the token lands in `email/tokens/`.

## Calendar

No live API pull (a consumer-Gmail OAuth app would need Google verification). It's a Takeout
snapshot rebuilt from `.ics`.

- **Rebuild:** `~/dotfiles/personal-mcp/calendar-refresh.sh` (re-parses `calendar/sources/*.ics` →
  the DuckDB, then — if LM Studio is up — embeds new events and rebuilds the `embeddings` table;
  embedding is best-effort and incremental, so it's cheap on re-runs).
- **Refresh recent events:** re-export via Google Takeout, drop the new `.ics` into
  `calendar/sources/` (overwrite the matching `gcal-*.ics`), then run the refresh.
- **Re-embed after content edits:** incremental embedding keys on UID, so it won't catch edited
  summaries of existing events — run `uv run ~/dotfiles/personal-mcp/calendar-archive/embed_calendar.py --all`
  then the build SQL to redo all vectors.
- **Query:** `duckdb ~/archives/calendar/calendar-archive.duckdb "SELECT … FROM events WHERE …"`
- **Semantic search:** via the MCP `semantic_search` tool (`source=calendar`), see Hub below.

## Web (Readwise Reader)

Independent local archive of everything saved to Reader (articles, blog posts, tweets, web
pages), pulled from the Reader API — same model as email/calendar (cloud is source, this is the
snapshot). Replaced the old Reader→Obsidian→iCloud markdown sync (retired). You still **save** to
Reader exactly as before (browser extension, share, email-forward); only the local mirror moved.

- **Auto-refresh:** nightly 4am via LaunchAgent `com.kylelundstedt.web-archive-refresh`
  (`~/dotfiles/personal-mcp/web-archive-refresh.sh`). Log: `/tmp/web-archive-refresh.log`. **Incremental:**
  pulls only docs updated since the last run (state in `sources/_pull_state.json`), upserts them
  into the jsonl, embeds only changed docs, then rebuilds the `documents`/`embeddings` tables from
  the merged files (cheap). Embeddings best-effort — skipped if LM Studio is down. Safe to run by hand.
- **Manual rebuild:** `S=~/dotfiles/personal-mcp/web; cd ~/archives/web && python3 $S/pull_reader.py &&
python3 $S/embed_reader.py && duckdb web-archive.duckdb < $S/build_documents.sql &&
duckdb web-archive.duckdb < $S/build_embeddings.sql`.
  `pull_reader.py`/`embed_reader.py` are incremental by default; pass `--full` / `--all` to rebuild
  everything from scratch (e.g. after changing the strip/embed logic). Incremental keeps docs you've
  deleted in Reader (it's an archive); edits and moves still propagate via `updated_at`.
- **Keyword search:** `~/dotfiles/personal-mcp/web/search.sh "query terms" [limit]` — BM25 over title + author +
  site + summary + full document text.
- **Semantic search:** `~/dotfiles/personal-mcp/web/semantic.sh "natural-language query" [limit]` — cosine over
  nomic embeddings (needs LM Studio up). Same endpoint/model as `email/config.toml`.
- **Query:** `duckdb ~/archives/web/web-archive.duckdb "SELECT … FROM documents WHERE …"`
- **Token:** Reader API token at `~/.config/readwise/token` (chmod 600, outside this dir so it
  stays out of the backup surface). Override with `READWISE_TOKEN`.

## Messages (iMessage/SMS attachments)

Message **text** (iMessage + SMS) is already in msgvault and the hub. What msgvault does _not_
import is text-message **attachments** — and on the Mac, Messages-in-iCloud keeps ~96% of them
offloaded (only on-demand per-image download exists; there is no bulk download). The fix is to go
through the **iPhone**, which keeps the bytes local:

1. **Encrypted iPhone backup** (first-party): iPhone → USB-C → Finder → _Encrypt local backup_ →
   Back Up Now. Backups are redirected to the external drive via a symlink:
   `~/Library/Application Support/MobileSync/Backup` → `/Volumes/OWC8TB/iPhoneBackup`.
2. **Browsable export** (open-source [`imessage-exporter`](https://github.com/ReagentX/imessage-exporter)):
   `imessage-exporter -p <backup-dir> -x <pw> -c basic -f html -o /Volumes/OWC8TB/messages-export`
   → per-conversation HTML with images inline (~24 GB, 1,627 conversations).
3. **Index for search** (`~/dotfiles/personal-mcp/messages/build_index.py`): decrypts `sms.db` for the authoritative
   message↔attachment metadata, maps each to its exported file (export filename = attachment
   ROWID), content-addresses the bytes into `/Volumes/OWC8TB/messages-store/`, and writes
   `messages/messages.duckdb`. ~9,160 attachments (~23 GB). The hub then folds these in.

Refresh is **manual / point-in-time** (a backup is a snapshot): re-backup the iPhone, re-run steps
2–3, rebuild the hub. The decrypted `sms.db` is sensitive (all message text) — keep it in a temp
dir, don't commit it.

## Hub (unified search)

One searchable index across all the archives. Normalizes email, iMessage/SMS, calendar, web, and
message attachments into a single `items` table (`source, ts, who, title, body, link`) with one
full-text index, so BM25 scores are comparable across sources. ~360k items (192k email + 94k
imessage + 30k sms + 42k calendar + 1.1k web; imessage/sms counts include ~9k attachment items).
Email is de-duplicated across ingest sources (the same message often lands in Gmail + an mbox);
counts reflect distinct messages, not ingest copies.

- **Search:** `~/dotfiles/personal-mcp/hub/search.sh "query" [limit] [email|imessage|sms|calendar|web]`
  → mixed hits across sources, ranked together.
- **Rebuild:** `cd ~/archives && duckdb hub/hub.duckdb < ~/dotfiles/personal-mcp/hub/build_hub.sql`. Runs automatically at
  the end of the 4am web refresh (after msgvault's 3am sync), so both are fresh; calendar and
  messages fold in on their manual rebuilds.
- **What it indexes:** email/iMessage/SMS = subject + snippet + sender (full bodies stay in
  `msgvault.db`); calendar = summary + location + description + organizer; web = title + author +
  full text; message attachments = filename + caption + sender (`link` = the stored file, openable).
  Note: msgvault's message _text_ currently lags (~last sync) while attachment items are current to
  the last iPhone backup.
- **Remote (tailnet):** the mini is `klundstedt-mini.dojo-sun.ts.net`. From any tailnet device:
  `ssh klundstedt-mini.dojo-sun.ts.net '~/dotfiles/personal-mcp/hub/search.sh "query" 10'` — or use the MCP
  server below.

### MCP server

`~/dotfiles/personal-mcp/mcp/server.py` (FastMCP, streamable-HTTP) exposes the hub to Claude/any
MCP client. The server code is versioned in the dotfiles repo; it reads the archives in this dir
via absolute `~/archives/...` paths. Tools:

- `search(query, limit, source?)` — keyword/BM25 across **all** archives (optional
  `source` = email|imessage|sms|calendar|web).
- `semantic_search(query, limit, source?)` — vector search over **web + calendar** (both nomic-768
  cosine stores; results merge into one ranked list). `source` restricts to `web` or `calendar`.
- `get_item(item_id)` — full record for one hub hit (web/calendar = full content; email/iMessage/SMS =
  snippet; message attachments = the openable file path in `link`).
- `query_messages(sender?, recipient?, since?, until?, source?, subject_contains?, is_from_me?, limit)`
  — **structured** filter over email/iMessage/SMS straight from msgvault. Use for exact
  sender/recipient/date filters and accurate (de-duplicated) counts — e.g. "how many emails from X".
  Returns `{count, returned, results}`.
- `get_message(item_id)` — **full body** + headers + to/cc/bcc for one message (where `get_item`
  returns only a snippet). email/iMessage/SMS only; bodies >100k chars are truncated.
- `semantic_search_email(query, limit)` — vector search over **email + iMessage/SMS** using
  msgvault's own nomic-768 vectors (`vectors.db`, sqlite-vec). Each hit has `distance` (lower =
  closer); results de-duplicated across ingest sources. Needs LM Studio up to embed the query.

Runtime:

- **Service:** LaunchAgent `com.kylelundstedt.personal-mcp` (`~/dotfiles/personal-mcp/personal-mcp.sh`),
  binds `127.0.0.1:8765`, KeepAlive. Log: `/tmp/personal-mcp.log`.
- **Tailnet exposure:** `tailscale serve --bg 8765` → tailnet-only HTTPS at
  `https://klundstedt-mini.dojo-sun.ts.net/mcp` (config persists; turn off with
  `tailscale serve --https=443 off`).
- **Connect a client** (device must be on the tailnet), e.g. Claude Code:
  `claude mcp add --transport http hub-mcp https://klundstedt-mini.dojo-sun.ts.net/mcp`
- **Reads are read-only, one connection per request**, so the nightly rebuild never collides.
- **Semantic coverage:** web + calendar (DuckDB cosine, merged via `semantic_search`) and
  email/iMessage/SMS (`semantic_search_email`, sqlite-vec L2). Every source now has meaning search.
- **Next (optional):** merge web/calendar + email into one ranked list. The stores use different
  distance metrics (cosine-similarity vs sqlite-vec L2), so it needs a normalization step first.

## Tooling (versioned in ~/dotfiles)

- `personal-mcp/msgvault-sync.sh` + `launchd/Library/LaunchAgents/com.kylelundstedt.msgvault-sync.plist`
- `personal-mcp/calendar-archive/` (`calendar_archive.py`, `embed_calendar.py`,
  `build_calendar_embeddings.sql`) + `personal-mcp/calendar-refresh.sh`
- `personal-mcp/web-archive-refresh.sh` + `launchd/Library/LaunchAgents/com.kylelundstedt.web-archive-refresh.plist`
  (launcher only; the build code it invokes now lives in the repo — see next two lines — and this
  job also rebuilds the unified hub at the end)
- `personal-mcp/web/` — `pull_reader.py`, `embed_reader.py`, `build_documents.sql`,
  `build_embeddings.sql`, `search.sh`, `semantic.sh` (read `~/archives/web`; override `WEB_ARCHIVE_DIR`)
- `personal-mcp/hub/` — `build_hub.sql`, `search.sh` (read `~/archives/hub`; override `HUB_ARCHIVE_DIR`)
- `personal-mcp/messages/build_index.py` — manual attachment backfill (all paths via args)
- `personal-mcp/personal-mcp.sh` (launcher) + `personal-mcp/mcp/` (the server itself: `server.py`,
  `pyproject.toml`, `uv.lock` — `.venv/` is gitignored, `uv` recreates it) +
  `launchd/Library/LaunchAgents/com.kylelundstedt.personal-mcp.plist`. The server reads the archives
  in `~/archives/` via absolute paths; `tailscale serve` config persists separately.

## Backup

`~/` (this whole `~/archives` dir included) plus the bulky external-drive data are backed up
nightly to Tigris, **client-side encrypted** (rclone `crypt` — Tigris holds ciphertext only).
Code: `~/dotfiles/backup/tigris-backup.sh` + `tigris-backup-excludes.txt`, run by LaunchAgent
`com.kylelundstedt.tigris-backup`. Mini-only (hostname-guarded), min 20h between runs.

- **`klundstedt-mini-backup`** — STANDARD_IA, **multi-region (usa)**, versioned, daily snapshots.
  Holds `~/` (minus excludes) + the Photos library. This is where `~/archives` lands (~634 GB).
- **`klundstedt-mini-archive`** — GLACIER, **multi-region (usa)**, versioned. The bulky
  external-drive data: `aws_s3_backup`, `Box_Download`, `iPhoneBackup`, `messages-store` (~658 GB).
- **Excluded** (regenerable / redundant): caches, `node_modules`/`.venv`/`__pycache__`,
  `Library/{Messages,Mail,Containers}` (already in iCloud/IMAP/msgvault), LM Studio model weights,
  and the derived `hub/hub.duckdb` (rebuilt nightly). Secrets (`email/tokens/`, client-secret JSON,
  `config.toml`) are not path-excluded but are safe — the whole upload is encrypted before it leaves
  the machine.
- **Integrity**: SQLite WAL is checkpointed (`PRAGMA wal_checkpoint(TRUNCATE)`) before copy so the
  `.db` files aren't torn; `--max-delete 5000` aborts a sync that would wipe the backup from a
  missing source; a healthchecks.io dead-man's-switch alerts on failure or silence.
- **Restore**: needs the rclone crypt password + salt (and, for the iPhone backup, its own
  encryption password) — all in the macOS login Keychain (`tigris-backup:*`), **not** in this repo.
  Lose the Keychain and the backups are unreadable.

## TODO

- **Test MCP access from other devices** — `klundstedt-mbp` (online) and `klundstedt-iphone`
  (currently **offline, last seen ~231d ago** — needs the Tailscale app reconnected first).
  Connect each to `https://klundstedt-mini.dojo-sun.ts.net/mcp`.
- **Message text freshness** — msgvault's `apple_messages` sync lags (hub `imessage`/`sms` text is
  current only to its last sync), while attachment items are current to the last iPhone backup.
  Either re-run the msgvault Apple Messages sync regularly, or source message text from the backup's
  `sms.db` too (which already has it, with attachment links).
- **Remove Web Clipper browser extension** — the vault `Clippings/` folder is gone; uninstall the
  extension from the browser so it stops offering to clip.

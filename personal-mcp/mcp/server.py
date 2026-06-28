#!/usr/bin/env python3
"""MCP server for unified search across the local archives (email + calendar + web).

Wraps the hub (~/archives/hub/hub.duckdb), the web vector store
(~/archives/web/web-archive.duckdb), and msgvault (~/archives/email/msgvault.db +
vectors.db). Exposes:

  Cross-archive (DuckDB hub):
  - search(query, limit, source)        keyword/BM25 across all archives
  - get_item(item_id)                   full record for one hub hit

  Web semantic (DuckDB web store):
  - semantic_search(query, limit)       vector search over saved web reading (Reader)

  Messages — structured + full-text + semantic (sqlite msgvault):
  - query_messages(...)                 structured filter: sender/recipient/date/source
  - get_message(item_id)                full body + headers + recipients for one message
  - semantic_search_email(query, limit) vector search over email/iMessage/SMS

Keyword `search` spans email + calendar + web on snippets only. For exact sender/
recipient/date filtering and full bodies, use the message tools (they hit msgvault
directly). Email semantic reuses msgvault's own nomic-768 vectors (sqlite-vec).

Transport: streamable-HTTP. Bind host/port via HUB_MCP_HOST / HUB_MCP_PORT.
Default binds 127.0.0.1; expose on the tailnet with `tailscale serve` (see README).

DuckDB is opened read-only, one short-lived connection per request, so the nightly
rebuild (which swaps the db file atomically) never collides with a live query.
"""
import json
import os
import sqlite3
import urllib.request

import duckdb
import sqlite_vec
from mcp.server.fastmcp import FastMCP
from mcp.server.transport_security import TransportSecuritySettings

HOME = os.path.expanduser("~")
HUB_DB = os.path.join(HOME, "archives", "hub", "hub.duckdb")
WEB_DB = os.path.join(HOME, "archives", "web", "web-archive.duckdb")
MSG_DB = os.path.join(HOME, "archives", "email", "msgvault.db")
VEC_DB = os.path.join(HOME, "archives", "email", "vectors.db")
EMBED_ENDPOINT = "http://localhost:1234/v1/embeddings"
EMBED_MODEL = "text-embedding-nomic-embed-text-v1.5@q8_0"
SOURCES = ("email", "imessage", "sms", "calendar", "web")
MSG_SOURCES = ("email", "imessage", "sms")  # the message_type values in msgvault
MAX_BODY_CHARS = 100_000  # cap full-body responses so MCP transport stays sane

# Served over the tailnet via `tailscale serve` (TLS-terminated, tailnet-only),
# so requests arrive with the tailnet Host header. Allowlist it for the SDK's
# DNS-rebinding check; the tailnet itself is the access boundary.
PUBLIC_HOST = os.environ.get("HUB_MCP_PUBLIC_HOST", "klundstedt-mini.dojo-sun.ts.net")
ALLOWED_HOSTS = [h for h in os.environ.get("HUB_MCP_ALLOWED_HOSTS", "").split(",") if h] or [
    PUBLIC_HOST, "127.0.0.1", "127.0.0.1:*", "localhost", "localhost:*",
]

mcp = FastMCP(
    "personal-mcp",
    host=os.environ.get("HUB_MCP_HOST", "127.0.0.1"),
    port=int(os.environ.get("HUB_MCP_PORT", "8765")),
    transport_security=TransportSecuritySettings(
        enable_dns_rebinding_protection=True,
        allowed_hosts=ALLOWED_HOSTS,
        allowed_origins=[f"https://{PUBLIC_HOST}", "http://127.0.0.1:*", "http://localhost:*"],
    ),
)


def _rows(db, sql, params=None, load_fts=False):
    con = duckdb.connect(db, read_only=True)
    try:
        if load_fts:
            con.execute("LOAD fts")
        cur = con.execute(sql, params or [])
        cols = [d[0] for d in cur.description]
        return [dict(zip(cols, r)) for r in cur.fetchall()]
    finally:
        con.close()


def _sqlite_rows(db, sql, params=None, load_vec=False):
    # Read-only so the nightly msgvault sync/embed never collides with a live query.
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    try:
        if load_vec:
            con.enable_load_extension(True)
            sqlite_vec.load(con)
            con.enable_load_extension(False)
        con.row_factory = sqlite3.Row
        cur = con.execute(sql, params or [])
        return [dict(r) for r in cur.fetchall()]
    finally:
        con.close()


def _item_id(message_type, mid):
    prefix = {"imessage": "imessage:", "sms": "sms:"}.get(message_type, "email:")
    return f"{prefix}{mid}"


def _embed_query(text):
    body = json.dumps({"model": EMBED_MODEL, "input": "search_query: " + text}).encode()
    req = urllib.request.Request(EMBED_ENDPOINT, data=body,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)["data"][0]["embedding"]


def do_search(query, limit=20, source=None):
    """Keyword/BM25 search across email + calendar + web. Optional source filter."""
    filt, params = "", [query]
    if source:
        if source not in SOURCES:
            raise ValueError(f"source must be one of {SOURCES}")
        filt = "AND source = ?"
        params.append(source)
    sql = f"""
        SELECT item_id, source, ts, who, title,
               substr(coalesce(body, ''), 1, 300) AS snippet, link,
               round(score, 3) AS score
        FROM (SELECT *, fts_main_items.match_bm25(iid, ?) AS score FROM items)
        WHERE score IS NOT NULL {filt}
        ORDER BY score DESC
        LIMIT {int(limit)}
    """
    rows = _rows(HUB_DB, sql, params, load_fts=True)
    for r in rows:
        r["ts"] = r["ts"].isoformat() if r.get("ts") else None
    return rows


def do_semantic(query, limit=15):
    """Semantic (vector) search over saved web reading (Readwise Reader)."""
    vec = _embed_query(query)
    sql = f"""
        SELECT 'web:' || d.id AS item_id, 'web' AS source, d.saved_at AS ts,
               coalesce(nullif(d.author,''), d.site_name) AS who, d.title,
               substr(coalesce(d.summary, d.text, ''), 1, 300) AS snippet, d.url AS link,
               round(array_cosine_similarity(e.vec, ?::FLOAT[768]), 4) AS score
        FROM documents d JOIN embeddings e USING (id)
        ORDER BY score DESC
        LIMIT {int(limit)}
    """
    rows = _rows(WEB_DB, sql, [vec])
    for r in rows:
        r["ts"] = r["ts"].isoformat() if r.get("ts") else None
    return rows


def do_get(item_id):
    """Full record for one item_id (e.g. 'web:01k...', 'email:12345', 'cal:...')."""
    rows = _rows(HUB_DB, "SELECT item_id, source, ts, who, title, body, link, extra "
                         "FROM items WHERE item_id = ? LIMIT 1", [item_id])
    if not rows:
        return {"error": f"no item {item_id!r}"}
    r = rows[0]
    r["ts"] = r["ts"].isoformat() if r.get("ts") else None
    if r["source"] in ("email", "imessage", "sms"):
        r["note"] = "body is a snippet; full message is in msgvault.db"
    return r


def do_query_messages(sender=None, recipient=None, since=None, until=None,
                      source=None, subject_contains=None, is_from_me=None, limit=50):
    """Structured filter over msgvault messages (email/iMessage/SMS). Returns count + rows."""
    where, params = ["1=1"], []
    if source:
        if source not in MSG_SOURCES:
            raise ValueError(f"source must be one of {MSG_SOURCES}")
        where.append("m.message_type = ?"); params.append(source)
    if sender:
        where.append("(sp.display_name LIKE ? OR sp.email_address LIKE ? OR sp.phone_number LIKE ?)")
        params += [f"%{sender}%"] * 3
    if recipient:
        where.append(
            "EXISTS (SELECT 1 FROM message_recipients mr JOIN participants rp ON rp.id = mr.participant_id "
            "WHERE mr.message_id = m.id AND (rp.display_name LIKE ? OR rp.email_address LIKE ? OR rp.phone_number LIKE ?))")
        params += [f"%{recipient}%"] * 3
    if since:
        where.append("m.sent_at >= ?"); params.append(since)
    if until:
        where.append("m.sent_at < ?"); params.append(until)
    if subject_contains:
        where.append("m.subject LIKE ?"); params.append(f"%{subject_contains}%")
    if is_from_me is not None:
        where.append("m.is_from_me = ?"); params.append(1 if is_from_me else 0)
    w = " AND ".join(where)
    base_from = "FROM messages m LEFT JOIN participants sp ON m.sender_id = sp.id"
    # Dedup to match the hub: the same EMAIL lands in several ingest sources, so collapse
    # on (sent_at, subject, sender). iMessage/SMS come from one source — key them by id so
    # each stays distinct. This makes counts reflect distinct messages, not ingest copies.
    dedup_key = ("CASE WHEN m.message_type IN ('imessage','sms') THEN 'id:' || m.id "
                 "ELSE 'email|' || m.sent_at || '|' || coalesce(m.subject, '') || '|' || m.sender_id END")
    count = _sqlite_rows(MSG_DB,
                         f"SELECT count(*) AS n FROM (SELECT 1 {base_from} WHERE {w} GROUP BY {dedup_key})",
                         params)[0]["n"]
    rows = _sqlite_rows(MSG_DB, f"""
        SELECT source, _id, ts, title, who, snippet, from_me FROM (
            SELECT m.message_type AS source, m.id AS _id, m.sent_at AS ts, m.subject AS title,
                   coalesce(nullif(sp.display_name, ''), sp.email_address, sp.phone_number) AS who,
                   m.snippet, m.is_from_me AS from_me,
                   row_number() OVER (PARTITION BY {dedup_key} ORDER BY m.id) AS _rn
            {base_from} WHERE {w}
        ) WHERE _rn = 1 ORDER BY ts DESC LIMIT ?
    """, params + [int(limit)])
    for r in rows:
        r["item_id"] = _item_id(r["source"], r.pop("_id"))
        r["from_me"] = bool(r["from_me"])
    return {"count": count, "returned": len(rows), "results": rows}


def do_get_message(item_id):
    """Full body + headers + recipients for one message item_id (email:/imessage:/sms:)."""
    try:
        prefix, raw = item_id.split(":", 1)
        mid = int(raw)
    except ValueError:
        return {"error": f"bad item_id {item_id!r}; expected like 'email:12345'"}
    if prefix not in MSG_SOURCES:
        return {"error": f"get_message handles {MSG_SOURCES}; use get_item for calendar/web/attachments"}
    base = _sqlite_rows(MSG_DB, """
        SELECT m.message_type AS source, m.sent_at AS ts, m.subject AS title, m.is_from_me AS from_me,
               coalesce(nullif(sp.display_name, ''), sp.email_address, sp.phone_number) AS sender,
               sp.email_address AS sender_email
        FROM messages m LEFT JOIN participants sp ON m.sender_id = sp.id WHERE m.id = ?""", [mid])
    if not base:
        return {"error": f"no message {item_id!r}"}
    r = base[0]
    r["item_id"] = item_id
    r["from_me"] = bool(r["from_me"])
    r["recipients"] = _sqlite_rows(MSG_DB, """
        SELECT mr.recipient_type AS kind,
               coalesce(nullif(rp.display_name, ''), rp.email_address, rp.phone_number) AS who
        FROM message_recipients mr JOIN participants rp ON rp.id = mr.participant_id
        WHERE mr.message_id = ? ORDER BY mr.recipient_type""", [mid])
    body = _sqlite_rows(MSG_DB, "SELECT body_text FROM message_bodies WHERE message_id = ?", [mid])
    text = (body[0]["body_text"] if body and body[0]["body_text"] else None)
    if text and len(text) > MAX_BODY_CHARS:
        r["body"] = text[:MAX_BODY_CHARS]
        r["body_truncated"] = True
    else:
        r["body"] = text
    return r


def do_semantic_email(query, limit=15):
    """Vector KNN over msgvault's nomic-768 embeddings (email + iMessage/SMS)."""
    vec = sqlite_vec.serialize_float32(_embed_query(query))
    over = max(int(limit) * 4, 40)  # over-fetch: chunks + cross-source dupes get collapsed below
    knn = _sqlite_rows(VEC_DB, """
        SELECT e.message_id AS mid, v.distance AS dist
        FROM vectors_vec_d768 v JOIN embeddings e ON e.embedding_id = v.embedding_id
        WHERE v.embedding MATCH ?
          AND v.generation_id = (SELECT id FROM index_generations WHERE state = 'active' ORDER BY id DESC LIMIT 1)
          AND k = ?
        ORDER BY v.distance
    """, [vec, over], load_vec=True)
    if not knn:
        return []
    best = {}  # min distance per message (a message can have several chunk vectors)
    for row in knn:
        if row["mid"] not in best or row["dist"] < best[row["mid"]]:
            best[row["mid"]] = row["dist"]
    ids = list(best)
    ph = ",".join("?" * len(ids))
    meta = _sqlite_rows(MSG_DB, f"""
        SELECT m.id AS _id, m.message_type AS source, m.sent_at AS ts, m.subject AS title,
               coalesce(nullif(sp.display_name, ''), sp.email_address, sp.phone_number) AS who,
               m.snippet, m.sent_at AS _k_sent, m.subject AS _k_subj, m.sender_id AS _k_sender
        FROM messages m LEFT JOIN participants sp ON m.sender_id = sp.id WHERE m.id IN ({ph})""", ids)
    by_id = {row["_id"]: row for row in meta}
    seen, out = set(), []
    for mid in sorted(best, key=best.get):  # nearest first
        row = by_id.get(mid)
        if not row:
            continue
        key = (row["_k_sent"], row["_k_subj"], row["_k_sender"])  # collapse cross-source dupes
        if key in seen:
            continue
        seen.add(key)
        row["item_id"] = _item_id(row["source"], row.pop("_id"))
        row["distance"] = round(best[mid], 4)  # lower = more similar (L2 over nomic vectors)
        for k in ("_k_sent", "_k_subj", "_k_sender"):
            row.pop(k, None)
        out.append(row)
        if len(out) >= int(limit):
            break
    return out


@mcp.tool()
def search(query: str, limit: int = 20, source: str | None = None) -> list[dict]:
    """Keyword search across email, iMessage/SMS, calendar, and web archives (BM25-ranked).

    Args:
        query: search terms.
        limit: max results (default 20).
        source: restrict to one of 'email', 'imessage', 'sms', 'calendar', 'web' (default: all).
    """
    return do_search(query, limit, source)


@mcp.tool()
def semantic_search(query: str, limit: int = 15) -> list[dict]:
    """Meaning-based search over saved web reading (Readwise Reader articles/tweets).

    Use for conceptual queries where exact keywords may not match. Covers the web
    archive only; for email use `search` (or msgvault's own semantic search).
    """
    return do_semantic(query, limit)


@mcp.tool()
def get_item(item_id: str) -> dict:
    """Fetch the full record for a single item_id returned by search/semantic_search."""
    return do_get(item_id)


@mcp.tool()
def query_messages(
    sender: str | None = None,
    recipient: str | None = None,
    since: str | None = None,
    until: str | None = None,
    source: str | None = None,
    subject_contains: str | None = None,
    is_from_me: bool | None = None,
    limit: int = 50,
) -> dict:
    """Structured query over messages (email/iMessage/SMS) — exact sender/recipient/date filters.

    Use this instead of `search` when you need precise filtering or an accurate count
    (e.g. "how many emails from X", "messages to Y in 2014"). Matches on the canonical
    msgvault metadata, so counts are de-duplicated by person, not by keyword relevance.

    Args:
        sender: substring of the sender's name / email / phone (case-insensitive).
        recipient: substring of any recipient's (to/cc/bcc) name / email / phone.
        since: ISO date/datetime lower bound, inclusive (e.g. '2014-01-01').
        until: ISO date/datetime upper bound, EXCLUSIVE (e.g. '2015-01-01').
        source: restrict to 'email', 'imessage', or 'sms' (default: all three).
        subject_contains: substring match on the subject line.
        is_from_me: True = only messages you sent; False = only received; None = both.
        limit: max rows returned (the count reflects ALL matches, not just returned).

    Returns: {count, returned, results:[{item_id, source, ts, title, who, snippet, from_me}]}.
    Pass an item_id to `get_message` for the full body.
    """
    return do_query_messages(sender, recipient, since, until, source,
                             subject_contains, is_from_me, limit)


@mcp.tool()
def get_message(item_id: str) -> dict:
    """Full body, headers, and recipients for one message (item_id like 'email:12345').

    Unlike `get_item` (which returns only a snippet for messages), this reads the full
    body_text from msgvault plus the to/cc/bcc list. Handles email/iMessage/SMS only;
    bodies over ~100k chars are truncated (body_truncated=true).
    """
    return do_get_message(item_id)


@mcp.tool()
def semantic_search_email(query: str, limit: int = 15) -> list[dict]:
    """Meaning-based search over email + iMessage/SMS (msgvault's nomic-768 vectors).

    Use for conceptual queries where keywords may not match. Complements `search`
    (keyword) and `semantic_search` (web only). Results are de-duplicated across
    ingest sources. Each hit has `distance` (lower = more similar); fetch the full
    body with `get_message`.
    """
    return do_semantic_email(query, limit)


def _ensure_fts():
    # read-only connections can't INSTALL; ensure the extension exists for this
    # duckdb version via a throwaway writable in-memory connection (idempotent).
    duckdb.connect().execute("INSTALL fts")


if __name__ == "__main__":
    _ensure_fts()
    mcp.run(transport="streamable-http")

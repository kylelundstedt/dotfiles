#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["duckdb"]
# ///
"""Embed calendar events via LM Studio -> sources/calendar-embeddings.jsonl.

Mirrors web/embed_reader.py, but the source is the calendar DuckDB (built from .ics
by calendar_archive.py) rather than a jsonl. Embeds summary + location + description
with the nomic "search_document: " prefix, one vector per distinct event UID
(recurring events repeat their UID, so we embed the UID once), keyed by UID.

Incremental by default: embeds only UIDs not already in the jsonl. Use --all to
re-embed everything (UID is stable, so incremental won't catch upstream text edits;
re-run with --all after a content change).

Then load into the DuckDB via build_calendar_embeddings.sql.

Data dir defaults to ~/archives/calendar; override with CALENDAR_ARCHIVE_DIR.

Usage:
  python3 embed_calendar.py          # incremental (missing UIDs)
  python3 embed_calendar.py --all    # re-embed all events
"""
import json, os, sys, urllib.request

import duckdb

CAL = os.environ.get("CALENDAR_ARCHIVE_DIR") or os.path.expanduser("~/archives/calendar")
DB = os.path.join(CAL, "calendar-archive.duckdb")
SRC = os.path.join(CAL, "sources")
OUT = os.path.join(SRC, "calendar-embeddings.jsonl")
ENDPOINT = "http://localhost:1234/v1/embeddings"
MODEL = "text-embedding-nomic-embed-text-v1.5@q8_0"
BATCH = 64
MAXCHARS = 6000  # ~nomic context budget


def embed(inputs):
    body = json.dumps({"model": MODEL, "input": inputs}).encode()
    req = urllib.request.Request(ENDPOINT, data=body,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=300) as r:
        d = json.load(r)
    return [e["embedding"] for e in d["data"]]


def event_input(summary, location, description):
    parts = [summary or "", location or "", description or ""]
    return "search_document: " + " ".join(p for p in parts if p)[:MAXCHARS]


def main():
    all_mode = "--all" in sys.argv
    os.makedirs(SRC, exist_ok=True)

    con = duckdb.connect(DB, read_only=True)
    rows = con.execute(
        "SELECT uid, any_value(summary), any_value(location), any_value(description) "
        "FROM events "
        "WHERE coalesce(summary,'') <> '' OR coalesce(location,'') <> '' OR coalesce(description,'') <> '' "
        "GROUP BY uid"
    ).fetchall()
    con.close()

    have = {}
    if os.path.exists(OUT):
        for line in open(OUT):
            d = json.loads(line)
            have[d["id"]] = d

    todo = [(uid, event_input(s, loc, desc)) for uid, s, loc, desc in rows
            if all_mode or uid not in have]
    print(f"embedding {len(todo)} events ({'all' if all_mode else 'incremental'}); "
          f"{len(have)} already cached")

    for i in range(0, len(todo), BATCH):
        chunk = todo[i:i + BATCH]
        vecs = embed([t for _, t in chunk])
        for (uid, _), v in zip(chunk, vecs):
            have[uid] = {"id": uid, "embedding": v}
        print(f"  {min(i + BATCH, len(todo))}/{len(todo)}", end="\r")
    print()

    tmp = OUT + ".tmp"
    with open(tmp, "w") as f:
        for d in have.values():
            f.write(json.dumps(d) + "\n")
    os.replace(tmp, OUT)
    print(f"done, {len(have)} total vectors in {OUT}")


if __name__ == "__main__":
    main()

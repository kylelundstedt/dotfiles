#!/usr/bin/env python3
"""Index iMessage/SMS attachments into a content-addressed store + a DuckDB table.

Bridges two artifacts produced from an encrypted iPhone backup:
  - sms.db (decrypted Messages database)  -> authoritative metadata + message link
  - the imessage-exporter HTML export     -> decrypted attachment bytes, named
                                             <attachment.ROWID>.<ext> in bucket dirs

For each real attachment file it: locates the exported file by attachment ROWID,
content-addresses it (sha256) into STORE_DIR (dedup), and records a row linking the
file to its owning message (date, sender, chat, caption text). The resulting
messages.duckdb feeds the unified hub (build_hub.sql) so attachments are searchable
by filename / caption / sender and openable via get_item.

One-time / manual backfill (the backup is a point-in-time snapshot, not nightly):
  uv run --with iOSbackup python build_index.py \
      --sms-db /path/to/sms.db \
      --export-dir /Volumes/OWC8TB/messages-export \
      --store-dir  /Volumes/OWC8TB/messages-store \
      --out-db     ~/archives/messages/messages.duckdb
"""
import argparse
import datetime
import hashlib
import os
import shutil
import sqlite3

import duckdb

APPLE_EPOCH = datetime.datetime(2001, 1, 1)
# attachments worth archiving (skip app plugin payloads / tapbacks / NULL-mime junk)
KEEP_PREFIXES = ("image/", "video/", "audio/")
KEEP_EXACT = {"application/pdf", "text/vcard", "text/x-vcard",
              "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
              "text/calendar", "application/pkpass"}


def apple_ts(raw):
    if not raw:
        return None
    # newer iOS stores nanoseconds since 2001; older stored seconds. Detect by magnitude.
    secs = raw / 1e9 if raw > 1e11 else raw
    try:
        return APPLE_EPOCH + datetime.timedelta(seconds=secs)
    except (OverflowError, OSError):
        return None


def wanted(mime):
    if not mime:
        return False
    return mime.startswith(KEEP_PREFIXES) or mime in KEEP_EXACT


def find_export_file(export_attach_dir, att_rowid, index):
    return index.get(att_rowid)


def build_rowid_index(export_attach_dir):
    """Map attachment ROWID -> exported file path (basename is the ROWID)."""
    idx = {}
    for root, _dirs, files in os.walk(export_attach_dir):
        for f in files:
            stem = f.rsplit(".", 1)[0]
            if stem.isdigit():
                idx[int(stem)] = os.path.join(root, f)
    return idx


def sha256(path, _buf=1024 * 1024):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(_buf), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sms-db", required=True)
    ap.add_argument("--export-dir", required=True)
    ap.add_argument("--store-dir", required=True)
    ap.add_argument("--out-db", required=True)
    args = ap.parse_args()

    export_attach = os.path.join(args.export_dir, "attachments")
    os.makedirs(args.store_dir, exist_ok=True)
    os.makedirs(os.path.dirname(os.path.expanduser(args.out_db)), exist_ok=True)

    print("Indexing exported files by attachment ROWID...")
    rowid_index = build_rowid_index(export_attach)
    print(f"  {len(rowid_index)} exported attachment files found")

    con = sqlite3.connect(f"file:{args.sms_db}?mode=ro", uri=True)
    rows = con.execute("""
        SELECT a.ROWID, a.mime_type, a.transfer_name, a.total_bytes,
               m.guid, m.date, m.is_from_me, m.text, m.service,
               h.id AS sender_id,
               c.chat_identifier, c.display_name
        FROM attachment a
        JOIN message_attachment_join maj ON maj.attachment_id = a.ROWID
        JOIN message m ON m.ROWID = maj.message_id
        LEFT JOIN handle h ON h.ROWID = m.handle_id
        LEFT JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        LEFT JOIN chat c ON c.ROWID = cmj.chat_id
        ORDER BY a.ROWID
    """).fetchall()

    seen = set()
    out = []
    copied = skipped_mime = no_file = dupes = 0
    store_bytes = 0
    for (att_rowid, mime, transfer_name, total_bytes, guid, date, is_from_me,
         text, service, sender_id, chat_identifier, display_name) in rows:
        if att_rowid in seen:        # message-in-multiple-chats: keep first
            continue
        seen.add(att_rowid)
        if not wanted(mime):
            skipped_mime += 1
            continue
        src = rowid_index.get(att_rowid)
        if not src or not os.path.exists(src):
            no_file += 1
            continue

        digest = sha256(src)
        ext = src.rsplit(".", 1)[-1].lower() if "." in os.path.basename(src) else "bin"
        rel = os.path.join(digest[:2], f"{digest}.{ext}")
        dst = os.path.join(args.store_dir, rel)
        if os.path.exists(dst):
            dupes += 1
        else:
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copy2(src, dst)
            copied += 1
            store_bytes += os.path.getsize(dst)

        ts = apple_ts(date)
        sender = "Me" if is_from_me else (sender_id or "(unknown)")
        chat_name = (display_name or "").strip() or chat_identifier or sender
        out.append((
            att_rowid, guid, ts, bool(is_from_me), sender,
            chat_identifier, chat_name, (service or "").lower(),
            mime, transfer_name, total_bytes, digest, dst, (text or ""),
        ))
        if (copied + dupes) % 500 == 0:
            print(f"  processed {len(out)} (copied {copied}, dup {dupes})")

    con.close()

    print(f"Writing index: {len(out)} attachments "
          f"({copied} copied / {dupes} dedup, {store_bytes/1e9:.2f} GB new), "
          f"skipped {skipped_mime} non-media, {no_file} missing bytes")

    db = duckdb.connect(os.path.expanduser(args.out_db))
    db.execute("DROP TABLE IF EXISTS message_attachments")
    db.execute("""
        CREATE TABLE message_attachments (
            att_rowid BIGINT, guid VARCHAR, ts TIMESTAMP, is_from_me BOOLEAN,
            sender VARCHAR, chat_identifier VARCHAR, chat_name VARCHAR,
            service VARCHAR, mime_type VARCHAR, filename VARCHAR,
            bytes BIGINT, content_hash VARCHAR, store_path VARCHAR, caption VARCHAR
        )
    """)
    db.executemany("INSERT INTO message_attachments VALUES "
                   "(?,?,?,?,?,?,?,?,?,?,?,?,?,?)", out)
    n = db.execute("SELECT count(*) FROM message_attachments").fetchone()[0]
    print(f"Done. messages.duckdb has {n} rows.")
    db.close()


if __name__ == "__main__":
    main()

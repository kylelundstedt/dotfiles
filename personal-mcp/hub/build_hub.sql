-- Unified search hub across the three archives (email + calendar + web).
-- Normalizes all sources into ONE `items` table with ONE full-text index, so
-- BM25 scores are directly comparable across sources.
--
-- Run from ~/archives so the relative paths resolve:
--   cd ~/archives && duckdb hub/hub.duckdb < hub/build_hub.sql
--
-- Rebuild after the source jobs refresh (msgvault 3am, web 4am, calendar manual).
INSTALL fts; LOAD fts;

ATTACH IF NOT EXISTS 'calendar/calendar-archive.duckdb' AS cal (READ_ONLY);
ATTACH IF NOT EXISTS 'web/web-archive.duckdb'           AS web (READ_ONLY);
ATTACH IF NOT EXISTS 'messages/messages.duckdb'         AS msg (READ_ONLY);

CREATE OR REPLACE TABLE items AS
WITH u AS (
    -- MESSAGES from msgvault: email + iMessage + SMS (the parquet's message_type
    -- distinguishes them). Metadata + snippet only; full bodies stay in msgvault.db,
    -- text-message attachments are indexed separately (see message_attachments).
    -- ~308k rows after email dedup (~334k raw − ~26k cross-source email duplicates).
    SELECT (CASE m.message_type WHEN 'imessage' THEN 'imessage:'
                                WHEN 'sms'      THEN 'sms:'
                                ELSE 'email:' END) || m.id     AS item_id,
           CASE m.message_type WHEN 'imessage' THEN 'imessage'
                               WHEN 'sms'      THEN 'sms'
                               ELSE 'email' END                AS source,
           m.sent_at                                          AS ts,
           m.subject                                          AS title,
           coalesce(nullif(p.display_name, ''), p.email_address) AS who,
           m.snippet                                          AS body,
           NULL                                               AS link,
           NULL                                               AS extra
    FROM read_parquet('email/analytics/messages/**/*.parquet', hive_partitioning=1) m
    LEFT JOIN read_parquet('email/analytics/participants/*.parquet') p
           ON m.sender_id = p.id
    -- Dedup EMAIL only: the same message often lands in several ingested sources
    -- (Gmail + mbox, or multiple mboxes), so it would otherwise appear N times and
    -- inflate counts. Collapse on (sent_at, subject, sender) keeping the lowest id.
    -- iMessage/SMS come from a single source, so partition them by id (each row gets
    -- a unique partition and is never collapsed). The parquet has no rfc822_message_id,
    -- so this natural key is the dedup proxy; all email is dated, so no NULL-ts risk.
    QUALIFY row_number() OVER (
        PARTITION BY CASE WHEN m.message_type IN ('imessage','sms') THEN 'msg:' || m.id
                          ELSE 'email|' || m.sent_at || '|' || coalesce(m.subject,'') || '|' || m.sender_id
                     END
        ORDER BY m.id
    ) = 1

    UNION ALL
    -- CALENDAR: events. who = organizer; body = location + description.
    SELECT 'cal:' || uid,
           'calendar',
           TRY_CAST(start_iso AS TIMESTAMP),
           summary,
           organizer,
           trim(coalesce(location, '') || ' ' || coalesce(description, '')),
           NULL,
           location
    FROM cal.events

    UNION ALL
    -- WEB: Reader docs. who = author/site; body = full text; link = url.
    SELECT 'web:' || id,
           'web',
           saved_at,
           title,
           coalesce(nullif(author, ''), site_name),
           text,
           url,
           site_name
    FROM web.documents

    UNION ALL
    -- MESSAGE ATTACHMENTS: iMessage/SMS/RCS photos, videos, docs recovered from the
    -- iPhone backup. title = filename; who = sender; body = caption text; link = the
    -- content-addressed file on the external store. RCS folds into 'sms' for filtering.
    SELECT 'msgatt:' || att_rowid,
           CASE service WHEN 'imessage' THEN 'imessage' ELSE 'sms' END,
           ts,
           filename,
           sender,
           caption,
           store_path,
           mime_type || ' · ' || chat_name
    FROM msg.message_attachments
)
-- Null out implausible timestamps (parse artifacts: email year 2 / 1601, calendar
-- 1604 = Windows FILETIME epoch). Keep the row; just drop the unusable date so it
-- stops leaking into date-sorted/filtered results.
SELECT row_number() OVER () AS iid,
       item_id, source,
       CASE WHEN ts >= TIMESTAMP '1996-01-01' AND ts < TIMESTAMP '2035-01-01' THEN ts END AS ts,
       title, who, body, link, extra
FROM u;

PRAGMA create_fts_index('items', 'iid', 'title', 'who', 'body', overwrite=1);

SELECT source, count(*) AS n, min(ts) AS earliest, max(ts) AS latest
FROM items GROUP BY source ORDER BY n DESC;

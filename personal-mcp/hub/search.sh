#!/usr/bin/env bash
# Unified keyword (BM25) search across email + calendar + web archives.
# Usage: ./search.sh "query terms" [limit] [source]
#   source (optional): email | calendar | web   (omit for all)
# Data dir (the hub.duckdb) defaults to ~/archives/hub; override with HUB_ARCHIVE_DIR.
set -euo pipefail
DB="${HUB_ARCHIVE_DIR:-$HOME/archives/hub}/hub.duckdb"
Q="${1:?usage: search.sh \"query\" [limit] [email|calendar|web]}"
N="${2:-20}"
SRC="${3:-}"
FILTER=""
[ -n "$SRC" ] && FILTER="AND source = '$(printf '%s' "$SRC" | sed "s/'/''/g")'"

duckdb "$DB" -box <<SQL
LOAD fts;
SELECT round(score, 2) AS score,
       source,
       strftime(ts, '%Y-%m-%d') AS date,
       substr(coalesce(who, ''), 1, 28) AS who,
       substr(coalesce(title, '(no title)'), 1, 70) AS title,
       link
FROM (
  SELECT *, fts_main_items.match_bm25(iid, '$(printf '%s' "$Q" | sed "s/'/''/g")') AS score
  FROM items
)
WHERE score IS NOT NULL $FILTER
ORDER BY score DESC
LIMIT $N;
SQL

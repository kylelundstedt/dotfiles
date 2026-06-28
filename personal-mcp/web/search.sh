#!/usr/bin/env bash
# Full-text search the Reader web archive (BM25-ranked), à la `msgvault search`.
# Usage: ./search.sh "query terms" [limit]
# Data dir (web-archive.duckdb) defaults to ~/archives/web; override with WEB_ARCHIVE_DIR.
set -euo pipefail
DB="${WEB_ARCHIVE_DIR:-$HOME/archives/web}/web-archive.duckdb"
Q="${1:?usage: search.sh \"query\" [limit]}"
N="${2:-15}"
duckdb "$DB" -box <<SQL
LOAD fts;
SELECT round(score,2) AS score,
       category AS cat,
       coalesce(nullif(author,''),site_name) AS source,
       strftime(saved_at,'%Y-%m-%d') AS saved,
       title,
       url
FROM (
  SELECT *, fts_main_documents.match_bm25(id, '$(printf '%s' "$Q" | sed "s/'/''/g")') AS score
  FROM documents
)
WHERE score IS NOT NULL
ORDER BY score DESC
LIMIT $N;
SQL

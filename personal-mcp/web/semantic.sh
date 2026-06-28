#!/usr/bin/env bash
# Semantic (vector) search over the Reader web archive — meaning, not keywords.
# Mirrors msgvault's embedding search. Requires LM Studio running (embeds the query).
# Usage: ./semantic.sh "natural language query" [limit]
# Data dir (web-archive.duckdb) defaults to ~/archives/web; override with WEB_ARCHIVE_DIR.
set -euo pipefail
DB="${WEB_ARCHIVE_DIR:-$HOME/archives/web}/web-archive.duckdb"
Q="${1:?usage: semantic.sh \"query\" [limit]}"
N="${2:-15}"

# Embed the query (nomic requires the "search_query: " prefix), emit as a SQL array literal.
VEC=$(python3 - "$Q" <<'PY'
import json, sys, urllib.request
q = "search_query: " + sys.argv[1]
body = json.dumps({"model": "text-embedding-nomic-embed-text-v1.5@q8_0", "input": q}).encode()
req = urllib.request.Request("http://localhost:1234/v1/embeddings", data=body,
                             headers={"Content-Type": "application/json"})
v = json.load(urllib.request.urlopen(req, timeout=60))["data"][0]["embedding"]
print("[" + ",".join(repr(x) for x in v) + "]")
PY
)

duckdb "$DB" -box <<SQL
SELECT round(array_cosine_similarity(e.vec, ${VEC}::FLOAT[768]), 3) AS sim,
       d.category AS cat,
       coalesce(nullif(d.author,''), d.site_name) AS source,
       strftime(d.saved_at,'%Y-%m-%d') AS saved,
       d.title,
       d.url
FROM documents d JOIN embeddings e USING (id)
ORDER BY sim DESC
LIMIT $N;
SQL

#!/usr/bin/env bash
# Create an atomic, consistent AgentsView SQLite snapshot for the encrypted
# Tigris home backup. The live data directory and raw remote mirrors are
# excluded from generic rclone sync; this staged copy is the backup authority.
set -euo pipefail
umask 077

source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
job_require_mini agentsview-snapshot

DATA_DIR=${AGENTSVIEW_DATA_DIR:-$HOME/.agentsview}
SRC="$DATA_DIR/sessions.db"
DEST="$HOME/archives/agentsview"
LOCKDIR=/tmp/agentsview-snapshot.lock

[[ -s "$SRC" ]] || { echo "FATAL: AgentsView database missing or empty: $SRC" >&2; exit 1; }
command -v sqlite3 >/dev/null 2>&1 || { echo "FATAL: sqlite3 not installed" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq not installed" >&2; exit 1; }
job_lock "$LOCKDIR" || { echo "FATAL: another AgentsView snapshot is running" >&2; exit 1; }
DB_TMP=""
MANIFEST_TMP=""
trap '[[ -z "$DB_TMP" ]] || rm -f "$DB_TMP"; [[ -z "$MANIFEST_TMP" ]] || rm -f "$MANIFEST_TMP"; rmdir "$LOCKDIR" 2>/dev/null || true' EXIT

mkdir -p "$DEST"
chmod 700 "$DEST"
DB_TMP="$DEST/.sessions.db.$$.tmp"
MANIFEST_TMP="$DEST/.manifest.json.$$.tmp"
rm -f "$DB_TMP" "$MANIFEST_TMP"

# sqlite3's online backup API produces a transactionally consistent copy while
# the collector remains live in WAL mode.
sqlite3 "$SRC" ".timeout 30000" ".backup '$DB_TMP'"
[[ "$(sqlite3 "$DB_TMP" 'PRAGMA integrity_check;')" == "ok" ]] || {
    echo "FATAL: snapshot integrity_check failed" >&2
    exit 1
}

size=$(wc -c < "$DB_TMP" | tr -d '[:space:]')
sha=$(shasum -a 256 "$DB_TMP" | awk '{print $1}')
created=$(date -u +%FT%TZ)
version_json=$(agentsview version --format json 2>/dev/null || printf '{"version":"unknown"}')

jq -n \
    --arg created_utc "$created" \
    --arg source "$SRC" \
    --arg sha256 "$sha" \
    --argjson size_bytes "$size" \
    --argjson agentsview "$version_json" \
    '{schema_version: 1, created_utc: $created_utc, source: $source,
      size_bytes: $size_bytes, sha256: $sha256, agentsview: $agentsview,
      integrity_check: "ok"}' > "$MANIFEST_TMP"

chmod 600 "$DB_TMP" "$MANIFEST_TMP"
mv -f "$DB_TMP" "$DEST/sessions.db"
mv -f "$MANIFEST_TMP" "$DEST/manifest.json"
echo "AgentsView snapshot: $created size=$size sha256=$sha"

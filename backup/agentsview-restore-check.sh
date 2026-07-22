#!/usr/bin/env bash
# Validate a staged/restored AgentsView archive without touching the live data
# directory. Usage: agentsview-restore-check.sh [snapshot-directory]
set -euo pipefail
umask 077

SNAPSHOT_DIR=${1:-$HOME/archives/agentsview}
DB="$SNAPSHOT_DIR/sessions.db"
MANIFEST="$SNAPSHOT_DIR/manifest.json"
[[ -s "$DB" && -s "$MANIFEST" ]] || {
    echo "FATAL: snapshot database or manifest missing in $SNAPSHOT_DIR" >&2
    exit 1
}

expected_sha=$(jq -r '.sha256 // empty' "$MANIFEST")
expected_size=$(jq -r '.size_bytes // empty' "$MANIFEST")
actual_sha=$(shasum -a 256 "$DB" | awk '{print $1}')
actual_size=$(wc -c < "$DB" | tr -d '[:space:]')
[[ -n "$expected_sha" && "$actual_sha" == "$expected_sha" ]] || {
    echo "FATAL: snapshot SHA-256 mismatch" >&2; exit 1;
}
[[ -n "$expected_size" && "$actual_size" == "$expected_size" ]] || {
    echo "FATAL: snapshot size mismatch" >&2; exit 1;
}
[[ "$(sqlite3 "$DB" 'PRAGMA integrity_check;')" == "ok" ]] || {
    echo "FATAL: snapshot integrity_check failed" >&2; exit 1;
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cp "$DB" "$TMP/sessions.db"
chmod 700 "$TMP"
chmod 600 "$TMP/sessions.db"
AGENTSVIEW_DATA_DIR="$TMP" AGENTSVIEW_NO_DAEMON=1 \
    agentsview session list --limit 1 --format json >/dev/null

echo "AgentsView restore check OK: size=$actual_size sha256=$actual_sha"

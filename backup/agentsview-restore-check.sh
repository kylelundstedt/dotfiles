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
SERVER_PID=""
cleanup() {
    [[ -z "$SERVER_PID" ]] || kill "$SERVER_PID" 2>/dev/null || true
    [[ -z "$SERVER_PID" ]] || wait "$SERVER_PID" 2>/dev/null || true
    rm -rf "$TMP"
}
trap cleanup EXIT
cp "$DB" "$TMP/sessions.db"
chmod 700 "$TMP"
chmod 600 "$TMP/sessions.db"

# Prove the restored archive opens through the real UI/API server, isolated
# from the live daemon and with sync disabled so no source state is touched.
port=$(python3 - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
)
AGENTSVIEW_DATA_DIR="$TMP" agentsview serve \
    --host 127.0.0.1 --port "$port" --no-browser --no-update-check --no-sync \
    >"$TMP/restore-server.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 50); do
    curl -fsS "http://127.0.0.1:$port/api/ping" >/dev/null 2>&1 && break
    kill -0 "$SERVER_PID" 2>/dev/null || {
        cat "$TMP/restore-server.log" >&2
        echo "FATAL: restored AgentsView server exited" >&2
        exit 1
    }
    sleep 0.2
done
curl -fsS "http://127.0.0.1:$port/api/ping" >/dev/null || {
    cat "$TMP/restore-server.log" >&2
    echo "FATAL: restored AgentsView server did not become ready" >&2
    exit 1
}
curl -fsS "http://127.0.0.1:$port/api/v1/sessions?limit=1" | jq -e . >/dev/null

echo "AgentsView restore check OK: size=$actual_size sha256=$actual_sha"

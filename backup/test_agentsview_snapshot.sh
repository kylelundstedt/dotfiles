#!/usr/bin/env bash
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home/.agentsview" "$TMP/bin"

cat > "$TMP/bin/scutil" <<'EOF'
#!/bin/sh
[ "$1 $2" = "--get LocalHostName" ] && echo klundstedt-mini
EOF
cat > "$TMP/bin/agentsview" <<'EOF'
#!/bin/sh
if [ "${1:-}" = version ]; then
    echo '{"schema_version":1,"name":"agentsview","version":"0.38.1","commit":"test","build_date":"2026-07-13T00:00:00Z"}'
    exit 0
fi
if [ "${1:-}" = serve ]; then
    shift
    port=8080
    while [ "$#" -gt 0 ]; do
        if [ "$1" = --port ]; then port=$2; shift 2; else shift; fi
    done
    exec python3 - "$port" <<'PY'
import http.server
import json
import sys

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        payload = {"ok": True} if self.path == "/api/ping" else {"sessions": []}
        body = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass

http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
PY
fi
exit 1
EOF
chmod +x "$TMP/bin/scutil" "$TMP/bin/agentsview"

sqlite3 "$TMP/home/.agentsview/sessions.db" \
    'PRAGMA journal_mode=WAL; CREATE TABLE sessions(id TEXT); INSERT INTO sessions VALUES("one");' \
    >/dev/null

HOME="$TMP/home" PATH="$TMP/bin:$PATH" "$REPO/backup/agentsview-snapshot.sh"
HOME="$TMP/home" PATH="$TMP/bin:$PATH" "$REPO/backup/agentsview-restore-check.sh"

MANIFEST="$TMP/home/archives/agentsview/manifest.json"
jq -e '.schema_version == 1 and .integrity_check == "ok" and
       .agentsview.version == "0.38.1" and .size_bytes > 0 and
       (.sha256 | length) == 64' "$MANIFEST" >/dev/null

echo "agentsview snapshot tests passed"

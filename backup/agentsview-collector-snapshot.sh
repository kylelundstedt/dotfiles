#!/usr/bin/env bash
# Stage a consistent snapshot of the FLEET AgentsView archive — the collector on
# iv-agentsview — under ~/archives/agentsview/collector, so the encrypted Tigris
# home backup carries it. Companion to agentsview-snapshot.sh, which stages the
# mini's OWN source database; until 2026-09-15 that was the only AgentsView
# snapshot, and since the 2026-09-02 demotion it has not contained the fleet:
# every session synced after that date lived only on the collector VM, an
# exe.dev VM with an ephemeral tailnet node and no backup of any kind.
#
# How: over the tailnet (tag:mini -> tag:dev tcp:22), run sqlite3's online
# backup API on the VM (transactionally consistent while the daemon stays live
# in WAL mode), verify it there, stream it here, verify it again, and stage it
# atomically with a manifest. config.toml comes along because a restore needs
# the [[remote_hosts]] blocks, cursor_secret and the mini's source token; it is
# 0600 inside the encrypted backup. sqlite3 was installed on the VM for this
# (exeslim has no python/sqlite3 by default). Runs from tigris-backup.sh before
# the home phase; a failure keeps the prior known-good staged copy and marks the
# backup job failed. Manual run: bash backup/agentsview-collector-snapshot.sh
set -euo pipefail
umask 077

source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
job_require_mini agentsview-collector-snapshot

VM=${AGENTSVIEW_COLLECTOR_HOST:-iv-agentsview}
REMOTE_DB='$HOME/.agentsview/sessions.db'
REMOTE_TMP=/tmp/av-collector-snapshot.db
DEST="$HOME/archives/agentsview/collector"
LOCKDIR=/tmp/agentsview-collector-snapshot.lock
SSH=(ssh -o ConnectTimeout=30 -o BatchMode=yes "$VM")

command -v sqlite3 >/dev/null 2>&1 || { echo "FATAL: sqlite3 not installed" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq not installed" >&2; exit 1; }
job_lock "$LOCKDIR" || { echo "FATAL: another collector snapshot is running" >&2; exit 1; }
DB_TMP=""; CFG_TMP=""; MANIFEST_TMP=""
cleanup() {
    [[ -z "$DB_TMP" ]] || rm -f "$DB_TMP"
    [[ -z "$CFG_TMP" ]] || rm -f "$CFG_TMP"
    [[ -z "$MANIFEST_TMP" ]] || rm -f "$MANIFEST_TMP"
    rmdir "$LOCKDIR" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "$DEST"; chmod 700 "$DEST"
DB_TMP="$DEST/.sessions.db.$$.tmp"
CFG_TMP="$DEST/.config.toml.$$.tmp"
MANIFEST_TMP="$DEST/.manifest.json.$$.tmp"
rm -f "$DB_TMP" "$CFG_TMP" "$MANIFEST_TMP"

# 1. Consistent copy on the VM, verified there. Prints: sha256 size sessions.
remote_meta=$(run_bounded 600 "${SSH[@]}" "set -euo pipefail; umask 077
  rm -f $REMOTE_TMP
  sqlite3 $REMOTE_DB '.timeout 30000' '.backup $REMOTE_TMP'
  [ \"\$(sqlite3 $REMOTE_TMP 'PRAGMA integrity_check;')\" = ok ]
  printf '%s %s %s\n' \"\$(sha256sum $REMOTE_TMP | cut -d' ' -f1)\" \"\$(stat -c %s $REMOTE_TMP)\" \"\$(sqlite3 $REMOTE_TMP 'select count(*) from sessions;')\"") || {
    echo "FATAL: remote snapshot failed on $VM" >&2; exit 1; }
read -r remote_sha remote_size remote_sessions <<<"$remote_meta"
[[ "$remote_sha" =~ ^[0-9a-f]{64}$ && "$remote_size" =~ ^[0-9]+$ ]] || { echo "FATAL: bad remote metadata: $remote_meta" >&2; exit 1; }

# 2. Stream it here (tailnet SSH has no SFTP; cat over ssh is the portable copy).
run_bounded 1200 "${SSH[@]}" "cat $REMOTE_TMP && rm -f $REMOTE_TMP" > "$DB_TMP" || {
    echo "FATAL: transfer from $VM failed" >&2; exit 1; }
"${SSH[@]}" "cat \$HOME/.agentsview/config.toml" > "$CFG_TMP"
version_json=$("${SSH[@]}" 'agentsview version --format json 2>/dev/null' || printf '{"version":"unknown"}')
[[ -n "$version_json" ]] || version_json='{"version":"unknown"}'

# 3. Verify the transfer against the VM-side hash, then switch the staged copy
# to the rollback journal — a backup artifact, not a live database — so later
# opens (integrity checks, restore-check) leave no -wal/-shm beside it. That
# rewrite changes the file, so the manifest hash is taken AFTER it (the first
# version hashed before, and restore-check rejected its own fresh snapshot).
xfer_size=$(wc -c < "$DB_TMP" | tr -d '[:space:]')
xfer_sha=$(shasum -a 256 "$DB_TMP" | awk '{print $1}')
[[ "$xfer_sha" == "$remote_sha" && "$xfer_size" == "$remote_size" ]] || {
    echo "FATAL: transfer mismatch (remote $remote_sha/$remote_size, local $xfer_sha/$xfer_size)" >&2; exit 1; }
[[ "$(sqlite3 "$DB_TMP" 'PRAGMA journal_mode=DELETE;')" == "delete" ]] || { echo "FATAL: could not set journal_mode" >&2; exit 1; }
rm -f "$DB_TMP-shm" "$DB_TMP-wal"
[[ "$(sqlite3 "$DB_TMP" 'PRAGMA integrity_check;')" == "ok" ]] || {
    echo "FATAL: local integrity_check failed" >&2; exit 1; }
size=$(wc -c < "$DB_TMP" | tr -d '[:space:]')
sha=$(shasum -a 256 "$DB_TMP" | awk '{print $1}')
cfg_sha=$(shasum -a 256 "$CFG_TMP" | awk '{print $1}')
[[ -s "$CFG_TMP" ]] || { echo "FATAL: config.toml empty" >&2; exit 1; }
created=$(date -u +%FT%TZ)

jq -n \
    --arg created_utc "$created" \
    --arg source "$VM:~/.agentsview/sessions.db" \
    --arg sha256 "$sha" \
    --argjson size_bytes "$size" \
    --argjson sessions "$remote_sessions" \
    --arg config_sha256 "$cfg_sha" \
    --argjson agentsview "$version_json" \
    '{schema_version: 1, created_utc: $created_utc, source: $source,
      size_bytes: $size_bytes, sha256: $sha256, sessions: $sessions,
      config_toml_sha256: $config_sha256, agentsview: $agentsview,
      integrity_check: "ok"}' > "$MANIFEST_TMP"

chmod 600 "$DB_TMP" "$CFG_TMP" "$MANIFEST_TMP"
mv -f "$DB_TMP" "$DEST/sessions.db"; DB_TMP=""
mv -f "$CFG_TMP" "$DEST/config.toml"; CFG_TMP=""
mv -f "$MANIFEST_TMP" "$DEST/manifest.json"; MANIFEST_TMP=""
echo "AgentsView collector snapshot: $created host=$VM sessions=$remote_sessions size=$size sha256=$sha"

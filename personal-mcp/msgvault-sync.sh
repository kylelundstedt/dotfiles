#!/usr/bin/env bash
# Sync the msgvault email archive (both Gmail accounts) and rebuild the analytics cache.
#
# Capability-guarded: no-ops on machines without msgvault, so it is safe to deploy
# everywhere via the stow-managed LaunchAgent but only does work on the archive host
# (klundstedt-mini). Safe to run by hand.
#
# Scheduled by a LaunchAgent (StartCalendarInterval, daily). See
#   launchd/Library/LaunchAgents/com.kylelundstedt.msgvault-sync.plist
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

# Only run where msgvault lives.
command -v msgvault >/dev/null 2>&1 || { echo "msgvault not installed; skipping."; exit 0; }

# Archive lives under ~/archives/email (consolidated layout, not the default ~/.msgvault).
export MSGVAULT_HOME="$HOME/archives/email"

LOCKDIR="/tmp/msgvault-sync.lock"
ACCOUNTS=("kylelundstedt@gmail.com" "klundstedt@industryvault.com")

# Atomic single-instance lock (mkdir works on macOS without flock).
if ! mkdir "$LOCKDIR" 2>/dev/null; then
    echo "Another msgvault sync is running; skipping."
    exit 0
fi
trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT

pm_setup_logging msgvault
pm_hc msgvault /start
echo "=== $(date '+%F %T') msgvault-sync START ==="

rc=0
for acct in "${ACCOUNTS[@]}"; do
    echo "==> Syncing $acct"
    if ! msgvault sync "$acct"; then
        echo "    Incremental sync failed for $acct; trying full sync."
        if ! msgvault sync-full "$acct"; then
            echo "    Full sync failed for $acct (token may need interactive re-auth)."
            rc=1
        fi
    fi
done

# Refresh iMessage/SMS *text* from the live Mac Messages DB (chat.db). Text is not
# offloaded by Messages-in-iCloud (only attachment bytes are), so the local DB is
# current; this keeps hub/keyword/structured search fresh to ~24h. Idempotent
# (upsert by source id); a 30-day window keeps it fast while tolerating missed runs.
# Needs Full Disk Access for THIS launchd agent (System Settings > Privacy &
# Security > Full Disk Access) — see README "Messages (iMessage/SMS)". Best-effort:
# a read failure (usually missing FDA) warns but does not fail the run, so it won't
# spam the healthcheck over a one-time permission gap. NOTE: import does not enqueue
# embeddings, so iMessage/SMS *semantic* lags until `embeddings build --full-rebuild`.
echo "==> Importing iMessage/SMS text (last 30 days)"
if ! msgvault import-imessage --after "$(date -v-30d +%F)"; then
    echo "    import-imessage failed — likely Full Disk Access not granted to this launchd"
    echo "    agent (see README). iMessage/SMS text stays at its last good import until fixed."
fi

echo "==> Rebuilding analytics cache"
msgvault build-cache || rc=1

# Enqueue recent iMessage/SMS for embedding so they follow the SAME incremental
# path as Gmail. `msgvault sync` enqueues new Gmail messages into the pending queue,
# but `import-imessage` does not -- so apple_messages would never reach semantic
# search via the incremental build. Insert recent unembedded iMessage/SMS text into
# the active generation's pending queue; `embeddings build` below then drains them
# along with the synced Gmail. Bounded to 35 days (new imports are always recent).
# Best-effort: reaches into msgvault's internal vectors.db, so guard on its presence
# and the sqlite3 tool, and never fail the run.
VEC="$MSGVAULT_HOME/vectors.db"
if command -v sqlite3 >/dev/null 2>&1 && [ -f "$VEC" ]; then
    echo "==> Enqueuing recent iMessage/SMS for embedding"
    sqlite3 "$VEC" "ATTACH '$MSGVAULT_HOME/msgvault.db' AS mv;
        INSERT OR IGNORE INTO pending_embeddings (generation_id, message_id, enqueued_at)
        SELECT g.id, m.id, strftime('%s','now')
        FROM mv.messages m JOIN mv.sources s ON m.source_id=s.id
        JOIN mv.message_bodies b ON b.message_id=m.id
        CROSS JOIN (SELECT id FROM index_generations WHERE state='active' LIMIT 1) g
        WHERE s.source_type='apple_messages' AND coalesce(b.body_text,'')<>''
          AND m.sent_at >= datetime('now','-35 days')
          AND NOT EXISTS (SELECT 1 FROM embeddings e WHERE e.message_id=m.id);" 2>/dev/null \
        || echo "    enqueue skipped (msgvault embedding schema not as expected)"
fi

# Embed newly-synced messages so they're reachable via semantic/hybrid search.
# Best-effort: needs LM Studio serving the embedding model. If it's not up, the
# messages stay pending and the next run drains them (incremental build is
# idempotent) -- so a missing endpoint warns but does not fail the sync.
echo "==> Embedding new messages"
LMS="$HOME/.lmstudio/bin/lms"
EMBED_MODEL="text-embedding-nomic-embed-text-v1.5@q8_0"
if [ -x "$LMS" ]; then
    # Ensure the model is loaded (no-op if already loaded; ignore errors).
    "$LMS" load "$EMBED_MODEL" --context-length 8192 --gpu max -y >/dev/null 2>&1 || true
fi
if ! msgvault embeddings build; then
    echo "    Embedding step failed (is LM Studio serving $EMBED_MODEL?); leaving messages pending for next run."
fi

if [ "$rc" -eq 0 ]; then
    pm_hc msgvault
    echo "=== $(date '+%F %T') msgvault-sync DONE (ok) ==="
else
    pm_hc msgvault /fail --data-raw "msgvault-sync failed (rc=$rc); see $PM_LOGDIR"
    echo "=== $(date '+%F %T') msgvault-sync DONE (rc=$rc) ==="
fi
exit "$rc"

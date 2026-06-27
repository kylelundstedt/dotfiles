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

echo "==> Rebuilding analytics cache"
msgvault build-cache || rc=1

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

exit "$rc"

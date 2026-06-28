#!/usr/bin/env bash
# Refresh the Readwise Reader web archive (~/archives/web).
#
# Capability-guarded: no-ops on machines without the archive, so it is safe to
# deploy everywhere via the stow-managed LaunchAgent but only does work on the
# archive host (klundstedt-mini). Safe to run by hand.
#
# Steps: pull all Reader docs via the API -> rebuild documents table + FTS index
#        -> (if LM Studio is up) embed docs + build the vector table for semantic search.
#
# Scheduled by a LaunchAgent (StartCalendarInterval, daily). See
#   launchd/Library/LaunchAgents/com.kylelundstedt.web-archive-refresh.plist
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

WEB="$HOME/archives/web"          # data (this host only)
SCRIPTS="$HOME/dotfiles/personal-mcp"  # build code (versioned in the repo)
[ -d "$WEB" ] || { echo "no $WEB; skipping."; exit 0; }
command -v duckdb >/dev/null 2>&1 || { echo "duckdb not installed; skipping."; exit 0; }

LOCKDIR="/tmp/web-archive-refresh.lock"
if ! mkdir "$LOCKDIR" 2>/dev/null; then
    echo "Another web-archive refresh is running; skipping."
    exit 0
fi
trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT

pm_setup_logging web
pm_hc web /start
echo "=== $(date '+%F %T') web-archive-refresh START ==="

cd "$WEB" || exit 1   # stay in the data dir: the *.sql read sources/ relative to cwd
rc=0

echo "==> Pulling Reader documents"
python3 "$SCRIPTS/web/pull_reader.py" || {
    echo "pull failed"; pm_hc web /fail --data-raw "web-archive pull failed (Reader API/token?)"; exit 1
}

echo "==> Rebuilding documents table + FTS index"
duckdb web-archive.duckdb < "$SCRIPTS/web/build_documents.sql" || rc=1

# Semantic search is best-effort: only if the local embedding endpoint is up.
if curl -s -m 5 http://localhost:1234/v1/models >/dev/null 2>&1; then
    echo "==> Embedding documents"
    if python3 "$SCRIPTS/web/embed_reader.py"; then
        echo "==> Building embeddings table"
        duckdb web-archive.duckdb < "$SCRIPTS/web/build_embeddings.sql" || rc=1
    else
        echo "    embedding failed; keeping previous vectors."
        rc=1
    fi
else
    echo "==> LM Studio not reachable; skipping embeddings (FTS still updated)."
fi

# Rebuild the unified search hub (email + calendar + web). Depends on all three;
# this job (4am) runs after msgvault (3am), so both are fresh by now.
# Build to a temp file and swap atomically so the personal-mcp server (read-only,
# one connection per request) never collides with the rebuild.
if [ -f "$SCRIPTS/hub/build_hub.sql" ]; then
    echo "==> Rebuilding unified search hub"
    if ( cd "$HOME/archives" && rm -f hub/hub.duckdb.tmp \
         && duckdb hub/hub.duckdb.tmp < "$SCRIPTS/hub/build_hub.sql" >/dev/null \
         && mv -f hub/hub.duckdb.tmp hub/hub.duckdb ); then :; else rc=1; fi
fi

if [ "$rc" -eq 0 ]; then
    pm_hc web
    echo "=== $(date '+%F %T') web-archive-refresh DONE (ok) ==="
else
    pm_hc web /fail --data-raw "web-archive-refresh failed (rc=$rc); see $PM_LOGDIR"
    echo "=== $(date '+%F %T') web-archive-refresh DONE (rc=$rc) ==="
fi
exit "$rc"

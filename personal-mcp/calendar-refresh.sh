#!/usr/bin/env bash
# Rebuild the local calendar archive from the .ics exports in ~/archives/calendar/sources/.
#
# Run by hand after refreshing the recent end: re-export the calendars via Google
# Takeout and drop the new files into ~/archives/calendar/sources/, overwriting the
# matching gcal-*.ics, then run this. (No live API pull — see calendar_archive.py.)
#
# Capability-guarded: no-ops where uv / the script / ~/archives aren't present, so it
# is safe to deploy everywhere but only does work on the archive host (klundstedt-mini).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

command -v uv >/dev/null 2>&1 || { echo "uv not installed; skipping."; exit 0; }
SCRIPT="$HOME/dotfiles/personal-mcp/calendar-archive/calendar_archive.py"
[ -f "$SCRIPT" ] || { echo "calendar_archive.py not found; skipping."; exit 0; }
[ -d "$HOME/archives" ] || { echo "~/archives not present; skipping."; exit 0; }

LOCKDIR="/tmp/calendar-refresh.lock"
if ! mkdir "$LOCKDIR" 2>/dev/null; then echo "Another refresh is running; skipping."; exit 0; fi
trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT

# Persistent logging only — calendar is a manual job (no fixed cadence), so a
# dead-man's-switch would false-alarm; no pm_hc here.
pm_setup_logging calendar

DIR="$HOME/dotfiles/personal-mcp/calendar-archive"

echo "==> Rebuilding calendar from .ics"
uv run --quiet "$SCRIPT" || exit 1

# Semantic search is best-effort: only embed if the local endpoint (LM Studio) is up.
# embed_calendar.py is incremental (new UIDs only); the embeddings table survives the
# events rebuild (calendar_archive.py only drops `events`).
if command -v duckdb >/dev/null 2>&1 && curl -s -m 5 http://localhost:1234/v1/models >/dev/null 2>&1; then
    echo "==> Embedding calendar events"
    if uv run --quiet "$DIR/embed_calendar.py"; then
        echo "==> Building calendar embeddings table"
        ( cd "$HOME/archives/calendar" \
          && duckdb calendar-archive.duckdb < "$DIR/build_calendar_embeddings.sql" )
    else
        echo "    calendar embedding failed; keeping previous vectors."
    fi
else
    echo "==> duckdb or LM Studio unavailable; skipping calendar embeddings."
fi

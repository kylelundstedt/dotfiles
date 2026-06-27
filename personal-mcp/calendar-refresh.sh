#!/usr/bin/env bash
# Rebuild the local calendar archive from the .ics exports in ~/archives/calendar-sources/.
#
# Run by hand after refreshing the recent end: re-export the calendars via Google
# Takeout and drop the new files into ~/archives/calendar-sources/, overwriting the
# matching gcal-*.ics, then run this. (No live API pull — see calendar_archive.py.)
#
# Capability-guarded: no-ops where uv / the script / ~/archives aren't present, so it
# is safe to deploy everywhere but only does work on the archive host (klundstedt-mini).
set -uo pipefail

command -v uv >/dev/null 2>&1 || { echo "uv not installed; skipping."; exit 0; }
SCRIPT="$HOME/dotfiles/personal-mcp/calendar-archive/calendar_archive.py"
[ -f "$SCRIPT" ] || { echo "calendar_archive.py not found; skipping."; exit 0; }
[ -d "$HOME/archives" ] || { echo "~/archives not present; skipping."; exit 0; }

LOCKDIR="/tmp/calendar-refresh.lock"
if ! mkdir "$LOCKDIR" 2>/dev/null; then echo "Another refresh is running; skipping."; exit 0; fi
trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT

exec uv run --quiet "$SCRIPT"

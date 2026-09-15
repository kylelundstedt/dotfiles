#!/usr/bin/env bash
# Restore drill — prove the Tigris backup is actually recoverable, not just uploaded.
# Read-only on Tigris: restores a small sample to a temp dir, verifies it decrypts
# and matches the local source, exercises a GLACIER fetch, then cleans up.
# SCHEDULED MONTHLY (com.kylelundstedt.restore-drill, 1st at 07:00) with its own
# healthchecks.io check, since 2026-09-15. Before that it was scheduled by
# nothing: the header said "run periodically (e.g. quarterly)", no launchd job
# existed, no check existed, and there was no log directory -- so there was no
# evidence it had EVER run. That matters more than the cadence, because
# tigris-backup.sh justifies skipping rclone's post-copy checksum on the grounds
# that "real integrity comes from the weekly reconcile (exact size+mtime) and
# restore-drill (cryptcheck + decrypt-and-compare)". Half of that argument was
# resting on a job with no mechanism behind it. Its first ever run, 2026-09-15,
# passed 3/3 in 6.7s.
#
# Monthly rather than quarterly because the run costs seven seconds and one
# small GLACIER_IR fetch: a quarterly drill leaves up to three months in which
# the backup could have stopped being restorable without anyone finding out.
#
# Pass --dry-run for a manual run that reports without pinging or logging.
set -uo pipefail

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

# Creds + rclone remotes (tigris/bkup/arch) come from the shared library —
# the same env the nightly writes with, so the drill proves the real path.
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
if (( ! DRY_RUN )); then
    job_require_mini restore-drill
    job_hc_init "restore-drill:healthcheck-url"
    job_log "$HOME/Library/Logs/restore-drill"
fi
tigris_rclone_env || {
    [[ $DRY_RUN -eq 1 ]] || job_hc /fail --data-raw "restore-drill $(date '+%F %T') tigris creds unavailable"
    exit 1
}
[[ $DRY_RUN -eq 1 ]] || job_hc /start

DRILL=$(mktemp -d /tmp/tigris-restore-drill.XXXXXX)
trap 'rm -rf "$DRILL"' EXIT
pass=0; fail=0
ok()   { echo "  PASS: $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL: $1"; fail=$((fail+1)); }

echo "=== $(date '+%F %T') restore drill -> $DRILL ==="

# 1) IA bucket: restore a small known subtree (Desktop) and verify it decrypts.
echo "[1] IA restore: bkup:home/Desktop"
if rclone copy bkup:home/Desktop "$DRILL/Desktop" --transfers 4 2>/dev/null; then
    n=$(find "$DRILL/Desktop" -type f 2>/dev/null | wc -l | tr -d ' ')
    [[ "$n" -gt 0 ]] && ok "decrypted $n file(s) from bkup:home/Desktop" || bad "restored 0 files (Desktop empty?)"
else
    bad "rclone copy bkup:home/Desktop failed"
fi

# 2) Integrity: restored content matches the live local source.
echo "[2] cryptcheck bkup:home/Desktop vs ~/Desktop"
if rclone cryptcheck "$HOME/Desktop" bkup:home/Desktop --one-way \
       --filter-from "$HOME/dotfiles/backup/tigris-backup-filter.txt" 2>&1 | grep -q "0 differences found"; then
    ok "cryptcheck clean (encrypted backup matches source)"
else
    bad "cryptcheck reported differences (investigate)"
fi

# 3) GLACIER bucket: fetch one small object to learn whether Archive needs a thaw.
echo "[3] GLACIER fetch: one small object from arch:box"
gfile=$(rclone lsf arch:box --files-only 2>/dev/null | head -1)
if [[ -z "$gfile" ]]; then
    echo "  SKIP: arch:box has no files yet (initial archive push may be pending)"
elif rclone copy "arch:box/$gfile" "$DRILL/glacier/" 2>/tmp/drill-glacier.err; then
    ok "GLACIER_IR object retrieved directly (no thaw needed): $gfile"
else
    # The archive tier is GLACIER_IR (instant retrieval) and this fetch has
    # passed since the 2026-07 re-tier — a failure now is a REGRESSION (e.g.
    # objects re-frozen to plain GLACIER), not a known limitation.
    bad "archive object not retrievable ($gfile) — tier regressed? see /tmp/drill-glacier.err"
fi

echo "=== drill done: $pass passed, $fail failed ==="
if (( ! DRY_RUN )); then
    if (( fail == 0 )); then
        # Empty first arg is the ping PATH (bare = success); passing --data-raw
        # as $1 would append it to the URL and 404 silently.
        job_hc "" --data-raw "restore-drill $(date '+%F %T') ok: $pass check(s) passed"
    else
        job_hc /fail --data-raw "restore-drill $(date '+%F %T') $fail of $((pass+fail)) check(s) FAILED -- backup may not be restorable"
    fi
fi
[[ "$fail" -eq 0 ]]

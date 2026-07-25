#!/usr/bin/env bash
# Encrypted incremental backup of klundstedt-mini -> Tigris.
#   home + photos                              -> klundstedt-mini-backup  (IA)
#   aws-s3 + box + iphone-backup + messages-store -> klundstedt-mini-archive (GLACIER_IR)
# Both buckets: client-side rclone crypt (Tigris holds ciphertext only) +
# soft-delete (30-day retention) for recoverable deletes/overwrites.
# Creds come from the macOS login Keychain (service "tigris-backup:*"), so the
# launchd jobs run unattended. Mini-only (guarded by hostname).
set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

MODE=${1:-daily}
case "$MODE" in
    daily)
        JOB_NAME=tigris-backup
        HC_SERVICE=tigris-backup:healthcheck-url
        LAST_RUN=/tmp/tigris-backup.lastrun
        MIN_INTERVAL=$((20 * 3600))
        RUN_LIMIT=$((2 * 3600))
        MODE_FLAGS=(--update --use-server-modtime)
        ;;
    reconcile)
        JOB_NAME=tigris-backup-reconcile
        HC_SERVICE=tigris-backup-reconcile:healthcheck-url
        LAST_RUN=/tmp/tigris-backup-reconcile.lastrun
        MIN_INTERVAL=$((6 * 24 * 3600))
        RUN_LIMIT=$((18 * 3600))
        MODE_FLAGS=()
        ;;
    *)
        echo "usage: $0 [daily|reconcile]" >&2
        exit 2
        ;;
esac

# Mini-only: this backs up THIS machine's home; must not run elsewhere.
job_require_mini "$JOB_NAME"

LOCKDIR=/tmp/tigris-backup.lock
FILTER="$HOME/dotfiles/backup/tigris-backup-filter.txt"
EXT=/Volumes/OWC8TB
# Max personal Photos originals allowed missing-from-disk before we refuse to
# sync the library (see photos_originals_complete). 0 = strict; bump a little if
# a freshly-shot photo still mid-download from iCloud flaps the gate at 04:00.
PHOTOS_MISSING_MAX=0
# Bound the metadata gate independently, while also clipping it to the shared
# run deadline below. osxphotos normally completes in seconds to minutes.
PHOTOS_GATE_LIMIT=${PHOTOS_GATE_LIMIT:-900}
PHOTOS_GATE_PYTHON=${PHOTOS_GATE_PYTHON:-/usr/bin/python3}
OSXPHOTOS_BIN=${OSXPHOTOS_BIN:-$HOME/.local/bin/osxphotos}

# Monitoring + skip/lock/log semantics come from _lib.sh (the skip pings
# success by construction — see the lib header for why that's load-bearing).
job_hc_init "$HC_SERVICE"

job_stale_skip "$LAST_RUN" "$MIN_INTERVAL" && { echo "ran ${JOB_STALE_AGE_H}h ago; skip"; exit 0; }
preflight_fail() {
    local reason="$1"
    echo "$reason"
    job_hc /fail --data-raw "$JOB_NAME $(scutil --get LocalHostName 2>/dev/null) $(date '+%F %T') $reason"
    exit 1
}
# Don't collide with another backup or an unrelated rclone transfer. A lock
# collision is a failed scheduled run, not a successful skip.
if pgrep -f "rclone (copy|sync)" >/dev/null 2>&1; then preflight_fail "rclone already running"; fi
# Single instance.
job_lock "$LOCKDIR" || preflight_fail "another tigris-backup mode is running"

job_log "$HOME/Library/Logs/$JOB_NAME"

HC_STARTED=0
HC_FINISHED=0
backup_exit() {
    local rc=$?
    rmdir "$LOCKDIR" 2>/dev/null || true
    if (( HC_STARTED && ! HC_FINISHED )); then
        job_hc /fail --data-raw "$JOB_NAME $(scutil --get LocalHostName 2>/dev/null) $(date '+%F %T') aborted (rc=$rc)"
    fi
    return "$rc"
}
trap backup_exit EXIT

job_hc /start
HC_STARTED=1
tigris_rclone_env || exit 1
FAILURES=()

# The archive sources + Photos live on the encrypted external drive, which comes
# up LOCKED after a reboot. Unlock/mount it from the keychain before syncing.
# If it still isn't mounted, register a FAILURE so the healthcheck goes red —
# otherwise the per-source SKIPs below would silently "succeed" with no backup.
if ! mount | grep -qF "on $EXT ("; then
    echo "external $EXT not mounted; attempting keychain unlock"
    bash "$HOME/dotfiles/backup/owc8tb-unlock.sh" || true
fi
if ! mount | grep -qF "on $EXT ("; then
    echo "external $EXT STILL not mounted after unlock attempt — archive sources unavailable"
    FAILURES+=("external-drive-unmounted")
fi

# Daily mode uses the S3 upload time for comparisons, avoiding one HEAD request
# per existing object. Weekly reconcile mode omits those flags and reads rclone's
# exact source mtime metadata. --max-delete guards against a missing/empty source.
FLAGS=(--fast-list --transfers 8 --checkers 16 --retries 5 --low-level-retries 10
       --max-delete 5000 --stats 5m --stats-log-level NOTICE --stats-one-line)
ABORT_REMAINING=0
# Keep the whole run inside its check's grace window. Each phase gets only the
# time remaining in the run-wide budget, so phase limits cannot stack.
RUN_DEADLINE=$(( $(date +%s) + RUN_LIMIT ))

sync_one() { # label src dest [extra...]
    local label="$1" src="$2" dest="$3"; shift 3
    if (( ABORT_REMAINING )); then echo "SKIP $label: an earlier phase exceeded its duration limit"; return 0; fi
    if [[ ! -d "$src" ]]; then echo "SKIP $label: source missing ($src)"; return 0; fi
    local remaining=$(( RUN_DEADLINE - $(date +%s) ))
    if (( remaining <= 0 )); then
        echo "WARN $label: run-wide deadline reached"
        FAILURES+=("$label(deadline)")
        ABORT_REMAINING=1
        return 0
    fi
    echo "$(date '+%F %T') sync $label: $src -> $dest"
    # rclone's own --max-duration is the graceful bound (exits rc=10). run_bounded
    # is the wall-clock BACKSTOP (+180s): if a wedged rclone ignores its own
    # deadline — as it did 2026-07-25, hung in finalize at 100% for 8h — the
    # backstop SIGKILLs it (rc=124) so the phase fails bounded instead of hanging
    # past the check grace. The +180s margin keeps a healthy run on rclone's path.
    run_bounded $(( remaining + 180 )) \
        caffeinate -i rclone sync "$src" "$dest" "${FLAGS[@]}" "${MODE_FLAGS[@]}" \
        --max-duration "${remaining}s" "$@"; local rc=$?
    if [[ $rc -ne 0 ]]; then
        echo "WARN $label sync rc=$rc"
        FAILURES+=("$label(rc=$rc)")
        if [[ $rc -eq 10 || $rc -eq 124 ]]; then
            echo "ABORT remaining phases: $label hit the run-wide duration limit (rc=$rc)"
            ABORT_REMAINING=1
        fi
    fi
}

# Flush WAL into the main file so rclone copies a consistent single-file snapshot
# (rclone transfers .db / -wal / -shm separately; a hot WAL can be torn or stale).
# TRUNCATE leaves an empty WAL. Cheap vs VACUUM INTO and safe here: the only writer
# (msgvault-sync, 03:00) has finished by 04:00 and the personal-mcp server is
# read-only. Best-effort -- a checkpoint failure never aborts the backup.
checkpoint_sqlite() { # path
    local db="$1"; [[ -f "$db" ]] || return 0
    if sqlite3 "$db" 'PRAGMA busy_timeout=10000; PRAGMA wal_checkpoint(TRUNCATE);' >/dev/null 2>&1; then
        echo "checkpointed $(basename "$db")"
    else
        echo "WARN checkpoint failed: $(basename "$db") (backing up as-is)"
    fi
}

# Photos completeness gate. rclone sync MIRRORS source->dest, so syncing a Photos
# library whose originals have been evicted (iCloud "Optimize Mac Storage", or a
# stalled "Download Originals" backfill) would DELETE those originals' ciphertext
# from the backup -- destroying the only complete copy. --max-delete 5000 won't
# catch a sub-threshold eviction, so verify completeness here first.
# Count ONLY our own library originals: shared-album photos and "Shared with You"
# syndication items are never stored as local originals by Apple, so they're
# legitimately absent and must be excluded (a raw Photos.sqlite query misclassifies
# them -- use osxphotos, which is schema-aware). Fail closed for Photos: any
# unavailable/error/malformed/timeout result skips only this source, records a
# failed run, and lets the unrelated archive phases continue.
photos_originals_complete() {
    local remaining timeout
    remaining=$(( RUN_DEADLINE - $(date +%s) ))
    if (( remaining <= 0 )); then
        echo "WARN photos-gate: run-wide deadline reached"
        return 15
    fi
    timeout=$PHOTOS_GATE_LIMIT
    (( remaining < timeout )) && timeout=$remaining
    if [[ ! -x "$PHOTOS_GATE_PYTHON" ]]; then
        echo "WARN photos-gate: Python runner unavailable ($PHOTOS_GATE_PYTHON)"
        return 11
    fi
    "$PHOTOS_GATE_PYTHON" "$HOME/dotfiles/backup/photos_gate.py" \
        --osxphotos "$OSXPHOTOS_BIN" \
        --library "$EXT/Photos Library.photoslibrary" \
        --missing-max "$PHOTOS_MISSING_MAX" \
        --timeout "$timeout"
}

echo "=== $(date '+%F %T') $JOB_NAME START (mode=$MODE) ==="
if command -v sqlite3 >/dev/null 2>&1; then
    checkpoint_sqlite "$HOME/archives/email/msgvault.db"
    checkpoint_sqlite "$HOME/archives/email/vectors.db"
else
    echo "WARN sqlite3 not found; skipping pre-sync checkpoint"
fi
# AgentsView is an active WAL database. Stage a transactionally consistent
# online-backup copy under ~/archives before the encrypted home sync; the live
# ~/.agentsview tree (including bearer tokens and remote mirrors) is excluded.
if bash "$HOME/dotfiles/backup/agentsview-snapshot.sh"; then
    echo "agentsview snapshot staged"
else
    echo "WARN AgentsView snapshot failed; retaining prior known-good snapshot"
    FAILURES+=("agentsview-snapshot")
fi
sync_one home   "$HOME/"                          bkup:home --filter-from "$FILTER"
if photos_originals_complete; then
    sync_one photos "$EXT/Photos Library.photoslibrary" bkup:photos
else
    photos_gate_rc=$?
    case "$photos_gate_rc" in
        10) photos_gate_failure=incomplete-library ;;
        11) photos_gate_failure=gate-unavailable ;;
        12) photos_gate_failure=gate-error ;;
        13) photos_gate_failure=malformed-output ;;
        14) photos_gate_failure=gate-timeout ;;
        15) photos_gate_failure=deadline ;;
        *)  photos_gate_failure="gate-rc=$photos_gate_rc" ;;
    esac
    echo "SKIP photos: $photos_gate_failure; not syncing (would risk deleting originals from backup)"
    FAILURES+=("photos($photos_gate_failure)")
fi
# Archive bucket: GLACIER_IR (Archive Instant Retrieval) — same $/GB as GLACIER
# but directly retrievable (plain GLACIER objects are frozen and need a thaw).
sync_one awss3  "$EXT/aws_s3_backup"              arch:aws-s3         --s3-storage-class GLACIER_IR
sync_one box    "$EXT/Box_Download_2025-01-12"    arch:box            --s3-storage-class GLACIER_IR
sync_one iphone "$EXT/iPhoneBackup"               arch:iphone-backup  --s3-storage-class GLACIER_IR
sync_one msgatt "$EXT/messages-store"             arch:messages-store --s3-storage-class GLACIER_IR

# Versioning/recovery is handled by bucket soft-delete (30-day retention) on both
# buckets — bounded and auto-expiring, so deleted/overwritten objects are
# recoverable for 30 days (ransomware / bad-sync / accidental-delete protection).
# We deliberately do NOT take daily snapshots: the CLI has no per-snapshot delete,
# so they'd accumulate unbounded. (Take a manual `tigris snapshots take` if ever
# you want a full point-in-time copy.)

if [[ ${#FAILURES[@]} -eq 0 ]]; then
    job_mark_done "$LAST_RUN"   # only mark success when every phase succeeded
    job_hc                       # success ping -> resets the dead-man's-switch
    HC_FINISHED=1
    echo "=== $(date '+%F %T') $JOB_NAME DONE (all phases OK) ==="
else
    echo "=== $(date '+%F %T') $JOB_NAME DONE WITH FAILURES: ${FAILURES[*]} ==="
    job_hc /fail --data-raw "$JOB_NAME $(scutil --get LocalHostName 2>/dev/null) $(date '+%F %T') failed: ${FAILURES[*]}"
    HC_FINISHED=1
    exit 1
fi

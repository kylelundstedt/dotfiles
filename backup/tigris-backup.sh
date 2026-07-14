#!/usr/bin/env bash
# Nightly encrypted incremental backup of klundstedt-mini -> Tigris.
#   home + photos                              -> klundstedt-mini-backup  (IA)
#   aws-s3 + box + iphone-backup + messages-store -> klundstedt-mini-archive (GLACIER_IR)
# Both buckets: client-side rclone crypt (Tigris holds ciphertext only) +
# soft-delete (30-day retention) for recoverable deletes/overwrites.
# Creds come from the macOS login Keychain (service "tigris-backup:*"), so the
# launchd job runs unattended. Mini-only (guarded by hostname).
set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# Mini-only: this backs up THIS machine's home; must not run elsewhere.
job_require_mini tigris-backup

LOCKDIR=/tmp/tigris-backup.lock
LAST_RUN=/tmp/tigris-backup.lastrun
MIN_INTERVAL=$((20 * 3600))
FILTER="$HOME/dotfiles/backup/tigris-backup-filter.txt"
EXT=/Volumes/OWC8TB
# Max personal Photos originals allowed missing-from-disk before we refuse to
# sync the library (see photos_originals_complete). 0 = strict; bump a little if
# a freshly-shot photo still mid-download from iCloud flaps the gate at 04:00.
PHOTOS_MISSING_MAX=0

# Monitoring + skip/lock/log semantics come from _lib.sh (the skip pings
# success by construction — see the lib header for why that's load-bearing).
job_hc_init "tigris-backup:healthcheck-url"

job_stale_skip "$LAST_RUN" "$MIN_INTERVAL" && { echo "ran ${JOB_STALE_AGE_H}h ago; skip"; exit 0; }
# Don't collide with an in-progress rclone (e.g. the initial push).
if pgrep -f "rclone (copy|sync)" >/dev/null 2>&1; then echo "rclone already running; skip"; exit 0; fi
# Single instance.
job_lock "$LOCKDIR" || { echo "another tigris-backup running; exit"; exit 0; }
trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT

job_log "$HOME/Library/Logs/tigris-backup"

tigris_rclone_env || exit 1

job_hc /start
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

# --max-delete aborts a sync that would remove an abnormal number of files
# (guards against a missing/empty source wiping the backup).
FLAGS="--fast-list --transfers 8 --checkers 16 --retries 5 --low-level-retries 10 --max-delete 5000 --stats 5m"

sync_one() { # label src dest [extra...]
    local label="$1" src="$2" dest="$3"; shift 3
    if [[ ! -d "$src" ]]; then echo "SKIP $label: source missing ($src)"; return 0; fi
    echo "$(date '+%F %T') sync $label: $src -> $dest"
    caffeinate -i rclone sync "$src" "$dest" $FLAGS "$@"; local rc=$?
    if [[ $rc -ne 0 ]]; then echo "WARN $label sync rc=$rc"; FAILURES+=("$label(rc=$rc)"); fi
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
# them -- use osxphotos, which is schema-aware). Fail-safe: if osxphotos can't run
# we fall back to the existing --max-delete guard and proceed with a WARN rather
# than block the photo backup indefinitely.
photos_originals_complete() {
    local uvx; uvx=$(command -v uvx || echo "$HOME/.local/bin/uvx")
    [[ -x "$uvx" ]] || { echo "WARN photos-gate: uvx not found; skipping completeness check"; return 0; }
    local missing
    missing=$("$uvx" osxphotos query --missing --not-syndicated --not-shared --count 2>/dev/null)
    if ! [[ "$missing" =~ ^[0-9]+$ ]]; then
        echo "WARN photos-gate: osxphotos check failed; backing up library as-is"; return 0
    fi
    if (( missing > PHOTOS_MISSING_MAX )); then
        echo "photos-gate: $missing personal originals NOT on disk (> $PHOTOS_MISSING_MAX)"; return 1
    fi
    echo "photos-gate: all personal originals present ($missing missing, threshold $PHOTOS_MISSING_MAX)"; return 0
}

echo "=== $(date '+%F %T') tigris-backup START ==="
if command -v sqlite3 >/dev/null 2>&1; then
    checkpoint_sqlite "$HOME/archives/email/msgvault.db"
    checkpoint_sqlite "$HOME/archives/email/vectors.db"
else
    echo "WARN sqlite3 not found; skipping pre-sync checkpoint"
fi
sync_one home   "$HOME/"                          bkup:home --filter-from "$FILTER"
if photos_originals_complete; then
    sync_one photos "$EXT/Photos Library.photoslibrary" bkup:photos
else
    echo "SKIP photos: library incomplete; not syncing (would delete originals from backup)"
    FAILURES+=("photos(incomplete-library)")
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
    echo "=== $(date '+%F %T') tigris-backup DONE (all phases OK) ==="
else
    echo "=== $(date '+%F %T') tigris-backup DONE WITH FAILURES: ${FAILURES[*]} ==="
    job_hc /fail --data-raw "tigris-backup $(scutil --get LocalHostName 2>/dev/null) $(date '+%F %T') failed: ${FAILURES[*]}"
fi

#!/usr/bin/env bash
# Nightly encrypted incremental backup of klundstedt-mini -> Tigris.
#   home + photos                              -> klundstedt-mini-backup  (IA)
#   aws-s3 + box + iphone-backup + messages-store -> klundstedt-mini-archive (GLACIER_IR)
# Both buckets: client-side rclone crypt (Tigris holds ciphertext only) +
# soft-delete (30-day retention) for recoverable deletes/overwrites.
# Creds come from the macOS login Keychain (service "tigris-backup:*"), so the
# launchd job runs unattended. Mini-only (guarded by hostname).
set -uo pipefail

# --- Mini-only: this backs up THIS machine's home; must not run elsewhere ---
if [[ "$(scutil --get LocalHostName 2>/dev/null)" != "klundstedt-mini" ]]; then
    echo "not klundstedt-mini; skipping tigris-backup."; exit 0
fi

LOCKDIR=/tmp/tigris-backup.lock
LAST_RUN=/tmp/tigris-backup.lastrun
MIN_INTERVAL=$((20 * 3600))
FILTER="$HOME/dotfiles/backup/tigris-backup-filter.txt"
EXT=/Volumes/OWC8TB
# Max personal Photos originals allowed missing-from-disk before we refuse to
# sync the library (see photos_originals_complete). 0 = strict; bump a little if
# a freshly-shot photo still mid-download from iCloud flaps the gate at 04:00.
PHOTOS_MISSING_MAX=0

# Skip if a recent run already completed.
if [[ -f "$LAST_RUN" ]]; then
    now=$(date +%s); last=$(cat "$LAST_RUN" 2>/dev/null || echo 0)
    if (( now - last < MIN_INTERVAL )); then echo "ran $(( (now-last)/3600 ))h ago; skip"; exit 0; fi
fi
# Don't collide with an in-progress rclone (e.g. the initial push).
if pgrep -f "rclone (copy|sync)" >/dev/null 2>&1; then echo "rclone already running; skip"; exit 0; fi
# Single instance.
mkdir "$LOCKDIR" 2>/dev/null || { echo "another tigris-backup running; exit"; exit 0; }
trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT

# Persistent, dated logs (launchd's /tmp log is wiped on reboot; keep 30 days).
LOGDIR="$HOME/Library/Logs/tigris-backup"; mkdir -p "$LOGDIR"
exec > >(tee -a "$LOGDIR/$(date +%F-%H%M%S).log") 2>&1
find "$LOGDIR" -name '*.log' -type f -mtime +30 -delete 2>/dev/null || true

kc() { security find-generic-password -s "tigris-backup:$1" -w 2>/dev/null; }
tid=$(kc s3-key-id); tsec=$(kc s3-secret); cpw=$(kc crypt-password); csalt=$(kc crypt-salt)
if [[ -z "$tid" || -z "$tsec" || -z "$cpw" || -z "$csalt" ]]; then
    echo "FATAL: tigris-backup creds missing from Keychain"; exit 1
fi

# Dead-man's-switch monitor (healthchecks.io). URL in Keychain (tigris-backup:healthcheck-url);
# pings are no-ops if it's unset. /start at begin, bare = success, /fail = failure (with summary).
HC_URL=$(kc healthcheck-url)
hc() { [[ -n "$HC_URL" ]] && curl -fsS -m 10 --retry 3 "${HC_URL}${1:-}" "${@:2}" >/dev/null 2>&1 || true; }
hc /start
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

export RCLONE_CONFIG_TIGRIS_TYPE=s3 RCLONE_CONFIG_TIGRIS_PROVIDER=Other
export RCLONE_CONFIG_TIGRIS_ACCESS_KEY_ID="$tid" RCLONE_CONFIG_TIGRIS_SECRET_ACCESS_KEY="$tsec"
export RCLONE_CONFIG_TIGRIS_ENDPOINT=https://t3.storage.dev RCLONE_CONFIG_TIGRIS_REGION=auto RCLONE_CONFIG_TIGRIS_ACL=private
ob_pw=$(rclone obscure "$cpw"); ob_salt=$(rclone obscure "$csalt")
export RCLONE_CONFIG_BKUP_TYPE=crypt RCLONE_CONFIG_BKUP_REMOTE=tigris:klundstedt-mini-backup
export RCLONE_CONFIG_BKUP_FILENAME_ENCRYPTION=standard RCLONE_CONFIG_BKUP_DIRECTORY_NAME_ENCRYPTION=true
export RCLONE_CONFIG_BKUP_PASSWORD="$ob_pw" RCLONE_CONFIG_BKUP_PASSWORD2="$ob_salt"
export RCLONE_CONFIG_ARCH_TYPE=crypt RCLONE_CONFIG_ARCH_REMOTE=tigris:klundstedt-mini-archive
export RCLONE_CONFIG_ARCH_FILENAME_ENCRYPTION=standard RCLONE_CONFIG_ARCH_DIRECTORY_NAME_ENCRYPTION=true
export RCLONE_CONFIG_ARCH_PASSWORD="$ob_pw" RCLONE_CONFIG_ARCH_PASSWORD2="$ob_salt"
export TIGRIS_STORAGE_ACCESS_KEY_ID="$tid" TIGRIS_STORAGE_SECRET_ACCESS_KEY="$tsec"

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
    date +%s > "$LAST_RUN"   # only mark success when every phase succeeded
    hc                        # success ping -> resets the dead-man's-switch
    echo "=== $(date '+%F %T') tigris-backup DONE (all phases OK) ==="
else
    echo "=== $(date '+%F %T') tigris-backup DONE WITH FAILURES: ${FAILURES[*]} ==="
    hc /fail --data-raw "tigris-backup $(scutil --get LocalHostName 2>/dev/null) $(date '+%F %T') failed: ${FAILURES[*]}"
fi

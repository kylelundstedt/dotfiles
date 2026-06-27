#!/usr/bin/env bash
# Nightly encrypted incremental backup of klundstedt-mini -> Tigris.
#   home + photos  -> klundstedt-mini-backup  (IA, snapshots enabled)
#   aws-s3 + box   -> klundstedt-mini-archive (GLACIER)
# Client-side encryption via rclone crypt; Tigris holds ciphertext only.
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
EXCLUDES="$HOME/dotfiles/tigris-backup-excludes.txt"
EXT=/Volumes/OWC8TB

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

kc() { security find-generic-password -s "tigris-backup:$1" -w 2>/dev/null; }
tid=$(kc s3-key-id); tsec=$(kc s3-secret); cpw=$(kc crypt-password); csalt=$(kc crypt-salt)
if [[ -z "$tid" || -z "$tsec" || -z "$cpw" || -z "$csalt" ]]; then
    echo "FATAL: tigris-backup creds missing from Keychain"; exit 1
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
FLAGS="--fast-list --transfers 8 --checkers 16 --retries 5 --low-level-retries 10 --max-delete 5000 --stats 0"

sync_one() { # label src dest [extra...]
    local label="$1" src="$2" dest="$3"; shift 3
    if [[ ! -d "$src" ]]; then echo "SKIP $label: source missing ($src)"; return 0; fi
    echo "$(date '+%F %T') sync $label: $src -> $dest"
    caffeinate -i rclone sync "$src" "$dest" $FLAGS "$@" || echo "WARN $label sync rc=$?"
}

echo "=== $(date '+%F %T') tigris-backup START ==="
sync_one home   "$HOME/"                          bkup:home --exclude-from "$EXCLUDES"
sync_one photos "$EXT/Photos Library.photoslibrary" bkup:photos
sync_one awss3  "$EXT/aws_s3_backup"              arch:aws-s3
sync_one box    "$EXT/Box_Download_2025-01-12"    arch:box

# Point-in-time snapshot of the live-data bucket (home/photos).
tigris snapshots take klundstedt-mini-backup "nightly-$(date +%F)" >/dev/null 2>&1 \
    && echo "snapshot taken" || echo "WARN: snapshot failed"

date +%s > "$LAST_RUN"
echo "=== $(date '+%F %T') tigris-backup DONE ==="

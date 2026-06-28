#!/usr/bin/env bash
# Restore drill — prove the Tigris backup is actually recoverable, not just uploaded.
# Read-only on Tigris: restores a small sample to a temp dir, verifies it decrypts
# and matches the local source, exercises a GLACIER fetch, then cleans up.
# Run periodically (e.g. quarterly). Uses the same Keychain creds as the nightly job.
set -uo pipefail

kc() { security find-generic-password -s "tigris-backup:$1" -w 2>/dev/null; }
tid=$(kc s3-key-id); tsec=$(kc s3-secret); cpw=$(kc crypt-password); csalt=$(kc crypt-salt)
if [[ -z "$tid" || -z "$tsec" || -z "$cpw" || -z "$csalt" ]]; then
    echo "FATAL: tigris-backup creds missing from Keychain"; exit 1
fi

export RCLONE_CONFIG_TIGRIS_TYPE=s3 RCLONE_CONFIG_TIGRIS_PROVIDER=Other
export RCLONE_CONFIG_TIGRIS_ACCESS_KEY_ID="$tid" RCLONE_CONFIG_TIGRIS_SECRET_ACCESS_KEY="$tsec"
export RCLONE_CONFIG_TIGRIS_ENDPOINT=https://t3.storage.dev RCLONE_CONFIG_TIGRIS_REGION=auto
ob_pw=$(rclone obscure "$cpw"); ob_salt=$(rclone obscure "$csalt")
for R in BKUP:klundstedt-mini-backup ARCH:klundstedt-mini-archive; do
    n=${R%%:*}; b=${R#*:}
    export RCLONE_CONFIG_${n}_TYPE=crypt RCLONE_CONFIG_${n}_REMOTE="tigris:$b"
    export RCLONE_CONFIG_${n}_FILENAME_ENCRYPTION=standard RCLONE_CONFIG_${n}_DIRECTORY_NAME_ENCRYPTION=true
    export RCLONE_CONFIG_${n}_PASSWORD="$ob_pw" RCLONE_CONFIG_${n}_PASSWORD2="$ob_salt"
done

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
       --exclude ".DS_Store" --exclude-from "$HOME/dotfiles/backup/tigris-backup-excludes.txt" 2>&1 | grep -q "0 differences found"; then
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
    ok "GLACIER object retrieved directly (no thaw needed): $gfile"
else
    echo "  INFO: GLACIER (Archive tier) object not directly retrievable — expected;"
    echo "        recovery requires a restore/thaw request first. Archive recovery is"
    echo "        UNVERIFIED until the thaw path is confirmed (see runbook 'Archive restore')."
fi

echo "=== drill done: $pass passed, $fail failed ==="
[[ "$fail" -eq 0 ]]

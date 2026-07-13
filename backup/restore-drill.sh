#!/usr/bin/env bash
# Restore drill — prove the Tigris backup is actually recoverable, not just uploaded.
# Read-only on Tigris: restores a small sample to a temp dir, verifies it decrypts
# and matches the local source, exercises a GLACIER fetch, then cleans up.
# Run periodically (e.g. quarterly). Uses the same Keychain creds as the nightly job.
set -uo pipefail

# Creds + rclone remotes (tigris/bkup/arch) come from the shared library —
# the same env the nightly writes with, so the drill proves the real path.
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
tigris_rclone_env || exit 1

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
    ok "GLACIER object retrieved directly (no thaw needed): $gfile"
else
    echo "  INFO: GLACIER (Archive tier) object not directly retrievable — expected;"
    echo "        recovery requires a restore/thaw request first. Archive recovery is"
    echo "        UNVERIFIED until the thaw path is confirmed (see runbook 'Archive restore')."
fi

echo "=== drill done: $pass passed, $fail failed ==="
[[ "$fail" -eq 0 ]]

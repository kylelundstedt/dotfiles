#!/usr/bin/env bash
# Unlock + mount the encrypted external APFS drive (OWC8TB) using the passphrase
# from the login keychain, so the always-on mini re-mounts it after a reboot with
# no interactive prompt. The drive holds the Tigris backup's archive sources +
# Photos library. Idempotent: no-op if already mounted. Mini-only (hostname guard).
#
# Passphrase: login keychain service "owc8tb-encryption" (mirrored from 1Password
# "OWC8TB disk encryption"; provisioned by install.sh on klundstedt-mini). The
# drive's data is independently recoverable from Tigris under a different key, so
# losing this passphrase does not lose the data.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

VOL_UUID=704B89D9-5896-4368-B518-D8CBD7EB4A15
MOUNT=/Volumes/OWC8TB
KC_SERVICE=owc8tb-encryption

job_require_mini owc8tb-unlock

# Already mounted (incl. while the initial encryption conversion is running)?
if mount | grep -qF "on $MOUNT ("; then
    exit 0
fi

pass=$(job_kc "$KC_SERVICE")
if [[ -z "$pass" ]]; then
    echo "FATAL: passphrase not found in keychain (service $KC_SERVICE)"; exit 1
fi

echo "$(date '+%F %T') unlocking $MOUNT ($VOL_UUID)"
printf %s "$pass" | diskutil apfs unlockVolume "$VOL_UUID" -stdinpassphrase
rc=$?
if [[ $rc -eq 0 ]] && mount | grep -qF "on $MOUNT ("; then
    echo "unlocked + mounted OK"; exit 0
fi
echo "FAILED to unlock/mount $MOUNT (rc=$rc)"; exit 1

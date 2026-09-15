#!/usr/bin/env bash
# Verify the disaster-recovery path: do the 1Password copies of the Tigris backup
# credentials still MATCH the Keychain values the backup actually runs with?
#
# WHY (2026-09-15). If the mini dies, restoring depends entirely on recovering
# these four values from 1Password. agent_docs/secrets.md records where they are
# mirrored and marks the crypt pair "DR-critical: never rotate without a plan" --
# but nothing has ever checked that the mirror is still accurate. A silently
# drifted 1Password copy looks exactly like a good one until the day it is the
# only copy left, and for the crypt password there is no recovery: the archive is
# unreadable without the exact original value.
#
# This is the cheap half of "can I restore without this machine". The other half,
# that the backup decrypts at all, is restore-drill.sh (monthly, monitored).
#
# NOT SCHEDULED, deliberately. `op` needs an interactive/biometric sign-in, so an
# unattended run would either fail every month or require a stored service-account
# token -- and issuing a 1Password credential that can read DR secrets, purely to
# check DR secrets, trades the thing being protected for the check. Run it by hand
# after any rotation, and once or twice a year otherwise.
#
# NEVER PRINTS A SECRET. Both sides are reduced to a SHA-256 and only the
# comparison is reported. Field names are not hardcoded: every field in the item
# is hashed and matched, so a renamed field is found rather than misreported.
#
#   ! op signin          # then:
#   ./backup/verify-dr-credentials.sh
set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

command -v op >/dev/null 2>&1 || { echo "FAIL: 1Password CLI (op) not installed"; exit 1; }
if ! op whoami >/dev/null 2>&1; then
    echo "FAIL: op is not signed in. Run:  ! op signin"
    exit 1
fi

# keychain-service | 1Password item reference (from agent_docs/secrets.md)
PAIRS=(
    "tigris-backup:s3-key-id|op://Personal/Tigris mini-backup rclone key"
    "tigris-backup:s3-secret|op://Personal/Tigris mini-backup rclone key"
    "tigris-backup:crypt-password|op://Personal/Tigris mini-backup rclone crypt"
    "tigris-backup:crypt-salt|op://Personal/Tigris mini-backup rclone crypt"
)

sha() { printf '%s' "$1" | shasum -a 256 | cut -c1-16; }

pass=0; fail=0
for pair in "${PAIRS[@]}"; do
    svc="${pair%%|*}"; ref="${pair#*|}"
    kc=$(job_kc "$svc")
    if [[ -z "$kc" ]]; then
        echo "  FAIL $svc — not in the login Keychain (the backup itself would fail)"
        fail=$((fail+1)); continue
    fi
    want=$(sha "$kc")
    # Hash every field value in the item and look for the Keychain value among
    # them. Avoids guessing field names, and reports a rename as "found under a
    # different field" rather than as a mismatch.
    item=$(op item get "${ref#op://*/}" --vault "$(printf '%s' "$ref" | cut -d/ -f3)" --format json 2>/dev/null)
    if [[ -z "$item" ]]; then
        echo "  FAIL $svc — 1Password item not readable: $ref"
        fail=$((fail+1)); continue
    fi
    match=""
    while IFS= read -r v; do
        [[ -z "$v" ]] && continue
        [[ "$(sha "$v")" == "$want" ]] && { match=yes; break; }
    done < <(printf '%s' "$item" | jq -r '.fields[]?|select(.value!=null)|.value')
    if [[ -n "$match" ]]; then
        echo "  PASS $svc — 1Password copy matches Keychain (sha ${want})"
        pass=$((pass+1))
    else
        echo "  FAIL $svc — NO field in '$ref' matches the Keychain value."
        echo "       The DR copy has drifted. For crypt-password/crypt-salt this is"
        echo "       unrecoverable if the Keychain is lost: fix the 1Password item now."
        fail=$((fail+1))
    fi
done

echo "=== DR credential check: $pass matched, $fail failed ==="
[[ "$fail" -eq 0 ]]

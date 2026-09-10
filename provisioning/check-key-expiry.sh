#!/usr/bin/env bash
# Credential expiry alarm — parses provisioning/keys.manifest and warns when
# any credential is expired or expiring soon. Scheduled monthly by launchd
# (com.kylelundstedt.check-key-expiry, 1st of the month); also run on demand.
#
# WARN_DAYS defaults to 35, not 14: the job runs monthly, so the warning
# window must exceed the check cadence or a key expiring 15–30 days after a
# run would sail past unwarned (e.g. an Aug 21 expiry checked Aug 1 needs a
# >20-day window).
#
# Dead-man's-switch heartbeat (healthchecks.io pattern shared with
# sync-repos/tigris-backup): ping URL in the login Keychain under
# key-expiry:healthcheck-url — optional, no-op if absent. Success ping when
# all keys are clear; /fail ping (with a summary) when anything is expiring.
#
# Reference verification (--verify-refs, default ON when stdin is a TTY, OFF
# for the launchd run): every op-ref in the manifest must name a vault and item
# that still exist in that account. One `op item list` per account — two
# prompts, never one per row — so the whole pass costs what install.sh costs.
# This is item-level on purpose: the failure it exists for is an item retitled
# or moved (2026-09-10: "Tailscale OAuth Dev" had become "Tailscale OAuth" and
# six references were stale for weeks), and field-level checks would double the
# prompts for a rarer failure. A missing item is a WARN -> /fail -> exit 1, the
# same as an expiring key. An account that cannot be listed (locked, denied,
# no op) is reported as unverified, not as a failure.
#
# Usage: check-key-expiry.sh [--warn-days N] [--manifest FILE] [--dry-run] [--verify-refs|--no-verify-refs]
#   --dry-run  report only; skip healthcheck pings
# Exit 1 when any key is expired or within the warning window, or a 1Password
# reference no longer resolves; else 0.
set -euo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/backup/_lib.sh"

WARN_DAYS=35
MANIFEST="$(cd "$(dirname "$0")" && pwd)/keys.manifest"
DRY_RUN=false
VERIFY_REFS=auto
while [[ $# -gt 0 ]]; do
    case "$1" in
        --warn-days) WARN_DAYS="$2"; shift 2 ;;
        --manifest)  MANIFEST="$2"; shift 2 ;;
        --dry-run)   DRY_RUN=true; shift ;;
        --verify-refs)    VERIFY_REFS=true; shift ;;
        --no-verify-refs) VERIFY_REFS=false; shift ;;
        *) echo "Usage: $0 [--warn-days N] [--manifest FILE] [--dry-run] [--verify-refs|--no-verify-refs]" >&2; exit 2 ;;
    esac
done
[[ "$VERIFY_REFS" == auto ]] && { [[ -t 0 ]] && VERIFY_REFS=true || VERIFY_REFS=false; }
[[ -f "$MANIFEST" ]] || { echo "check-key-expiry: manifest not found: $MANIFEST" >&2; exit 2; }

# Monitoring semantics from _lib.sh; --dry-run gates the pings locally.
job_hc_init "key-expiry:healthcheck-url"
hc() { $DRY_RUN && return 0; job_hc "$@"; }

# BSD (macOS) date first, GNU fallback
to_epoch() { date -j -f "%Y-%m-%d" "$1" +%s 2>/dev/null || date -d "$1" +%s; }

now=$(date +%s)
warnings=()
unknowns=()

while IFS='|' read -r name type expires opref fanout; do
    name="$(job_trim "$name")"; expires="$(job_trim "$expires")"
    [[ -z "$name" ]] && continue
    case "$expires" in
        none)    echo "  [ok]      $name — non-expiring" ;;
        unknown) echo "  [unknown] $name — no expiry recorded (fill in keys.manifest)"; unknowns+=("$name") ;;
        *)
            if ! exp_epoch=$(to_epoch "$expires" 2>/dev/null); then
                echo "  [WARN]    $name — unparseable expiry '$expires'"; warnings+=("$name: bad date '$expires'")
                continue
            fi
            days_left=$(( (exp_epoch - now) / 86400 ))
            if (( days_left < 0 )); then
                echo "  [EXPIRED] $name — expired $((-days_left))d ago ($expires)"; warnings+=("$name: EXPIRED $expires")
            elif (( days_left <= WARN_DAYS )); then
                echo "  [WARN]    $name — expires in ${days_left}d ($expires)"; warnings+=("$name: ${days_left}d left ($expires)")
            else
                echo "  [ok]      $name — ${days_left}d left ($expires)"
            fi
            ;;
    esac
done < <(grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$MANIFEST")

# --- 1Password reference verification --------------------------------------
verify_refs() {
    command -v op >/dev/null 2>&1 || { echo "  [skip]    reference check: op not installed"; return 0; }
    local accts="" line name opref ref acct vault rest item
    # Collect account -> "vault/item" pairs from every row with an op-ref.
    local -a rows=()
    while IFS='|' read -r name _ _ opref _; do
        name="$(job_trim "$name")"; opref="$(job_trim "$opref")"
        [[ -z "$name" || "$opref" == "-" || "$opref" != op://* ]] && continue
        ref="${opref%% @ *}"; acct="${opref##* @ }"
        rest="${ref#op://}"; vault="${rest%%/*}"; rest="${rest#*/}"; item="${rest%%/*}"
        rows+=("$acct|$vault|$item|$name")
        [[ " $accts " == *" $acct "* ]] || accts+=" $acct"
    done < <(grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$MANIFEST")
    echo ""
    echo "1Password references (one prompt per account):"
    for acct in $accts; do
        local listing
        if ! listing=$(op item list --account "$acct" --format json 2>/dev/null) || [[ -z "$listing" ]]; then
            echo "  [unverified] $acct — could not list items (locked, denied, or no session); references not checked"
            continue
        fi
        # "vault/title" lines; jq is present wherever op is provisioned.
        # The account's default vault answers to three names: references say
        # `Personal` (and resolve), the listing reports the real title — `Employee`
        # in the IndustryVault account, `Private` in the personal one. Normalise
        # all three to one token on both sides, or every default-vault item
        # reads as missing while `op read` on it works (first run, 2026-09-10).
        local have; have=$(printf '%s' "$listing" | jq -r '.[] | "\(.vault.name)/\(.title)"' 2>/dev/null |
            sed -E 's#^(Personal|Private|Employee)/#DEFAULT/#')
        for line in "${rows[@]}"; do
            IFS='|' read -r a vault item name <<<"$line"
            [[ "$a" == "$acct" ]] || continue
            local lookup="$vault"; case "$vault" in Personal|Private|Employee) lookup=DEFAULT ;; esac
            if grep -qxF "$lookup/$item" <<<"$have"; then
                echo "  [ok]      $name — op://$vault/$item exists"
            else
                echo "  [MISSING] $name — no item '$item' in vault '$vault' of $acct (retitled, moved, or deleted; fix keys.manifest and every consumer in agent_docs/secrets.md)"
                warnings+=("$name: op://$vault/$item not found in $acct")
            fi
        done
    done
}
$VERIFY_REFS && verify_refs

echo ""
[[ ${#unknowns[@]} -gt 0 ]] && echo "${#unknowns[@]} credential(s) with unrecorded expiry: ${unknowns[*]}"
if [[ ${#warnings[@]} -gt 0 ]]; then
    summary=$(printf '%s; ' "${warnings[@]}")
    echo "check-key-expiry: ${#warnings[@]} problem(s) — expiring keys or unresolvable references (see agent_docs/secrets.md)"
    hc "/fail" --data-raw "$summary"
    exit 1
fi
echo "check-key-expiry: all recorded expiries clear (warn window ${WARN_DAYS}d)$($VERIFY_REFS && echo ", references verified" || echo ", references not verified (--verify-refs)")"
hc
exit 0

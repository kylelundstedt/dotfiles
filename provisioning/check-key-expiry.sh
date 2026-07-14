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
# Usage: check-key-expiry.sh [--warn-days N] [--manifest FILE] [--dry-run]
#   --dry-run  report only; skip healthcheck pings
# Exit 1 when any key is expired or within the warning window, else 0.
set -euo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/backup/_lib.sh"

WARN_DAYS=35
MANIFEST="$(cd "$(dirname "$0")" && pwd)/keys.manifest"
DRY_RUN=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --warn-days) WARN_DAYS="$2"; shift 2 ;;
        --manifest)  MANIFEST="$2"; shift 2 ;;
        --dry-run)   DRY_RUN=true; shift ;;
        *) echo "Usage: $0 [--warn-days N] [--manifest FILE] [--dry-run]" >&2; exit 2 ;;
    esac
done
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

echo ""
[[ ${#unknowns[@]} -gt 0 ]] && echo "${#unknowns[@]} credential(s) with unrecorded expiry: ${unknowns[*]}"
if [[ ${#warnings[@]} -gt 0 ]]; then
    summary=$(printf '%s; ' "${warnings[@]}")
    echo "check-key-expiry: ${#warnings[@]} credential(s) expiring — rotate now (see agent_docs/secrets.md)"
    hc "/fail" --data-raw "$summary"
    exit 1
fi
echo "check-key-expiry: all recorded expiries clear (warn window ${WARN_DAYS}d)"
hc
exit 0

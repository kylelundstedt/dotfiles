#!/usr/bin/env bash
# Drift check: the healthchecks.io check configs (live API) must match
# provisioning/checks.manifest. Catches the class of failure where a job's
# launchd schedule moves but its check schedule doesn't (daily UP/DOWN
# flapping, 2026-07-11..13) — and dashboard typos like '* 4 * * *'.
#
# Needs the read-write API key in the login Keychain (healthchecks:api-key,
# mini-only); exits 0 with a skip message elsewhere. Exit 1 on drift.
#
# --operational additionally asserts that monitoring is still WORKING, not just
# configured. Two blind spots cost real incidents:
#
#   1. A check can be perfectly configured and never receive a ping. This script
#      vouched for `agentsview-retention` every run from 2026-07-28 to 08-26
#      while it sat at n_pings=0 — schedule, grace, channel and manifest row all
#      correct, but the ping call was malformed and 404'd silently. Configuration
#      was asserted; ARRIVAL never was.
#   2. healthchecks.io alerts on the TRANSITION into DOWN, so a check that is
#      already red never alerts again. `tigris-backup` was red for 41 days
#      (2026-07-27..09-06); when its failure got much worse on 08-27 — backup
#      never completing, four archive phases skipped nightly, the weekly verify
#      blocked — that produced exactly the same silence as the day before. A
#      stuck check is indistinguishable from a healthy one from the inbox.
#
# The STUCK assertion re-raises those: when a check has been down longer than the
# threshold, THIS check fails, so its own UP->DOWN transition fires a fresh alert
# about a stale problem. That is one new alert, not repeating ones — if the
# underlying check stays broken this one stays red and also goes quiet. It turns
# "never told again" into "told once more, days in", which is the gap that
# mattered. A genuine fix for repeat notification needs a digest, not a check.
set -uo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/backup/_lib.sh"

OPERATIONAL=0
[[ "${1:-}" == "--operational" ]] && OPERATIONAL=1
# How long a check may sit DOWN before we treat it as no longer alerting.
STUCK_AFTER=${MONITORING_STUCK_AFTER:-$((3 * 24 * 3600))}
# First-seen-down timestamps. The API exposes status and last_ping but not a
# down-since: a job pinging /fail hourly has a fresh last_ping while being red
# for weeks, so duration has to be tracked here.
STATE_DIR="$HOME/Library/Application Support/check-monitoring"
STATE="$STATE_DIR/down-since.tsv"

MANIFEST="$(cd "$(dirname "$0")" && pwd)/checks.manifest"
KEY=$(job_kc "healthchecks:api-key")
if [[ -z "$KEY" ]]; then
    echo "  [skip] healthchecks:api-key not in Keychain — cannot verify check configs"
    exit 0
fi
command -v jq >/dev/null 2>&1 || { echo "  [skip] jq not found"; exit 0; }

API_JSON=$(curl -fsS -m 15 -H "X-Api-Key: $KEY" https://healthchecks.io/api/v3/checks/) || {
    echo "  [skip] healthchecks API unreachable"; exit 0
}

FAIL=0
ok()     { echo "  [ok]   $*"; }
drift()  { echo "  [DRIFT] $*"; FAIL=1; }
silent() { echo "  [SILENT] $*"; FAIL=1; }
stuck()  { echo "  [STUCK] $*"; FAIL=1; }

seen_names=()
while IFS='|' read -r name sched tz grace job; do
    name=$(job_trim "$name"); sched=$(job_trim "$sched"); tz=$(job_trim "$tz"); grace=$(job_trim "$grace")
    [[ -z "$name" ]] && continue
    seen_names+=("$name")
    row=$(jq -c --arg n "$name" '.checks[] | select(.name == $n)' <<<"$API_JSON")
    if [[ -z "$row" ]]; then
        drift "check '$name' missing on healthchecks.io"
        continue
    fi
    case "$sched" in
        cron:*)
            want="${sched#cron:}"
            got=$(jq -r '.schedule // ""' <<<"$row")
            got_tz=$(jq -r '.tz // ""' <<<"$row")
            [[ "$got" == "$want" ]] && ok "$name schedule '$got'" || drift "$name schedule is '$got', manifest says '$want'"
            [[ "$got_tz" == "$tz" ]] && ok "$name tz $got_tz" || drift "$name tz is '$got_tz', manifest says '$tz'"
            ;;
        period:*)
            want="${sched#period:}"
            got=$(jq -r '.timeout // ""' <<<"$row")
            [[ "$got" == "$want" ]] && ok "$name period ${got}s" || drift "$name period is '${got}s', manifest says '${want}s'"
            ;;
        *) drift "$name: unknown schedule form '$sched' in manifest" ;;
    esac
    got_grace=$(jq -r '.grace' <<<"$row")
    [[ "$got_grace" == "$grace" ]] && ok "$name grace ${got_grace}s" || drift "$name grace is ${got_grace}s, manifest says ${grace}s"
    # A check with the right schedule but no notification channel is a dead-man's
    # switch wired to nothing: it flips to DOWN and tells no one. The agentsview
    # collector sat DOWN ~3 days this way (2026-07-25). Assert every registered
    # check routes somewhere.
    got_ch=$(jq -r '.channels // ""' <<<"$row")
    [[ -n "$got_ch" ]] && ok "$name has a notification channel" || drift "$name has NO notification channel (alerts go nowhere)"
    # ARRIVAL, not just configuration. A manifest check at n_pings=0 has never
    # been exercised: either the job has never run or its ping is malformed.
    # Right config with nothing arriving is worse than no check, because
    # everything above this line reports it as covered.
    #
    # NOTE this fails for a check legitimately created minutes ago whose job has
    # not run yet. That is the intended trade: a newly added check is expected to
    # be exercised once before it counts as wired, and the noise is bounded to
    # one run. Kickstart the job rather than waiting it out.
    got_pings=$(jq -r '.n_pings // 0' <<<"$row")
    if [[ "$got_pings" -gt 0 ]]; then ok "$name has been pinged (${got_pings})"
    else silent "$name has NEVER been pinged (n_pings=0) — configured but not wired"; fi
done < <(grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$MANIFEST")

# Reverse: every live check must be in the manifest (unmonitored-by-registry)
while IFS= read -r live; do
    found=false
    for n in "${seen_names[@]}"; do [[ "$n" == "$live" ]] && found=true && break; done
    $found || drift "live check '$live' not in checks.manifest"
done < <(jq -r '.checks[].name' <<<"$API_JSON")

if (( OPERATIONAL )); then
    echo ""
    NOW=$(date +%s)
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    [[ -f "$STATE" ]] || : > "$STATE"
    NEW_STATE=$(mktemp -t check-monitoring-state) || NEW_STATE=""
    while IFS=$'\t' read -r cname cstatus; do
        [[ -z "$cname" ]] && continue
        # A paused check is not monitoring anything and never will until resumed.
        # It reads as "not down", which is the same trap as a stuck check.
        if [[ "$cstatus" == "paused" ]]; then
            silent "$cname is PAUSED — not monitoring"
            continue
        fi
        if [[ "$cstatus" != "down" ]]; then
            ok "$cname is $cstatus"
            continue
        fi
        since=$(grep -F "$cname"$'\t' "$STATE" 2>/dev/null | head -1 | cut -f2)
        # Tolerate a corrupt/non-numeric state entry by restarting its clock
        # rather than aborting the whole pass.
        case "$since" in ''|*[!0-9]*) since="" ;; esac
        if [[ -z "$since" ]]; then
            # No tracked start: this check went down before we began tracking, or
            # the state file is new. Seeding with $NOW would under-report exactly
            # the number that matters -- a check down for weeks would read as
            # "down 0h" on the first run and never trip the STUCK threshold until
            # 3 more days had passed. So recover the real start from the API: the
            # last ping that was neither a failure nor a /start is the last time
            # this check was actually healthy. Costs one request, and only for
            # checks that are already down with no state.
            cuuid=$(jq -r --arg n "$cname" '.checks[]|select(.name==$n)|.uuid // ""' <<<"$API_JSON")
            if [[ -n "$cuuid" ]]; then
                lastok=$(curl -fsS -m 15 -H "X-Api-Key: $KEY" \
                    "https://healthchecks.io/api/v3/checks/$cuuid/pings/" 2>/dev/null \
                    | jq -r '[.pings[]?|select(.type!="fail" and .type!="start")][0].date // ""' 2>/dev/null)
                # A check broken longer than the retained ping window has no
                # success to find at all (tigris-backup-reconcile: last success
                # 2026-08-23, every retained ping a fail). Fall back to the
                # OLDEST retained ping, which makes the duration a lower bound
                # instead of resetting it to zero -- "down at least 2d" is true
                # and trips the threshold; "down 0h" is neither.
                [[ -z "$lastok" ]] && lastok=$(curl -fsS -m 15 -H "X-Api-Key: $KEY" \
                    "https://healthchecks.io/api/v3/checks/$cuuid/pings/" 2>/dev/null \
                    | jq -r '[.pings[]?]|last|.date // ""' 2>/dev/null)
                if [[ -n "$lastok" ]]; then
                    since=$(date -j -u -f "%Y-%m-%dT%H:%M:%S" "${lastok:0:19}" +%s 2>/dev/null || echo "")
                fi
            fi
            [[ -z "$since" ]] && since=$NOW
        fi
        down_for=$(( NOW - since ))
        [[ -n "$NEW_STATE" ]] && printf '%s\t%s\n' "$cname" "$since" >> "$NEW_STATE"
        if (( down_for >= STUCK_AFTER )); then
            stuck "$cname has been DOWN $(( down_for / 86400 ))d $(( (down_for % 86400) / 3600 ))h — past $(( STUCK_AFTER / 86400 ))d, so healthchecks.io has stopped alerting on it"
        else
            echo "  [down]  $cname is down $(( down_for / 3600 ))h (alerting normally; flagged at $(( STUCK_AFTER / 86400 ))d)"
        fi
    done < <(jq -r '.checks[] | [.name, .status] | @tsv' <<<"$API_JSON")
    # Replace state wholesale so recovered checks drop out and their clock resets.
    [[ -n "$NEW_STATE" ]] && mv "$NEW_STATE" "$STATE" 2>/dev/null || true
fi

echo ""
if [[ $FAIL -eq 0 ]]; then
    echo "check-monitoring: no drift$( (( OPERATIONAL )) && echo ", nothing silent or stuck")"
else
    echo "check-monitoring: PROBLEMS FOUND"
fi
exit $FAIL

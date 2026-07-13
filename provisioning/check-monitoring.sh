#!/usr/bin/env bash
# Drift check: the healthchecks.io check configs (live API) must match
# provisioning/checks.manifest. Catches the class of failure where a job's
# launchd schedule moves but its check schedule doesn't (daily UP/DOWN
# flapping, 2026-07-11..13) — and dashboard typos like '* 4 * * *'.
#
# Needs the read-write API key in the login Keychain (healthchecks:api-key,
# mini-only); exits 0 with a skip message elsewhere. Exit 1 on drift.
set -uo pipefail

MANIFEST="$(cd "$(dirname "$0")" && pwd)/checks.manifest"
KEY=$(security find-generic-password -s "healthchecks:api-key" -w 2>/dev/null)
if [[ -z "$KEY" ]]; then
    echo "  [skip] healthchecks:api-key not in Keychain — cannot verify check configs"
    exit 0
fi
command -v jq >/dev/null 2>&1 || { echo "  [skip] jq not found"; exit 0; }

API_JSON=$(curl -fsS -m 15 -H "X-Api-Key: $KEY" https://healthchecks.io/api/v3/checks/) || {
    echo "  [skip] healthchecks API unreachable"; exit 0
}

FAIL=0
ok()    { echo "  [ok]   $*"; }
drift() { echo "  [DRIFT] $*"; FAIL=1; }

trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

seen_names=()
while IFS='|' read -r name sched tz grace job; do
    name=$(trim "$name"); sched=$(trim "$sched"); tz=$(trim "$tz"); grace=$(trim "$grace")
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
done < <(grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$MANIFEST")

# Reverse: every live check must be in the manifest (unmonitored-by-registry)
while IFS= read -r live; do
    found=false
    for n in "${seen_names[@]}"; do [[ "$n" == "$live" ]] && found=true && break; done
    $found || drift "live check '$live' not in checks.manifest"
done < <(jq -r '.checks[].name' <<<"$API_JSON")

echo ""
if [[ $FAIL -eq 0 ]]; then echo "check-monitoring: no drift"; else echo "check-monitoring: DRIFT FOUND"; fi
exit $FAIL

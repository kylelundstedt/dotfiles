#!/usr/bin/env bash
# Deploy the control-plane-side scheduled checks to the iv-provision VM from the
# mini. Mirrors provisioning/iv-agentsview/deploy.sh. Jobs: entire-push-check
# (daily) and lmstudio-door (every 15 min; agent_docs/llm-relay.md).
#
# Only the SCHEDULING and the heartbeat are pushed. The check itself
# (bin/entire-push-check) is versioned in the iv-provision repo and already
# checked out on the VM, so it updates by git pull there rather than by being
# copied out of this repo -- one copy, one source of truth.
#
# The healthchecks.io ping URL is the single value that has to live on the VM,
# in ~/.config/entire-push-check/env (mode 0600, loaded by the unit). It can only
# spoof a heartbeat; the read-write API key stays in the mini Keychain.
#
# One SSH connection at a time — exe.dev drops parallel SYNs from one IP.
# Idempotent: the timer is re-enabled and units reloaded only when they change.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
VM=${1:-iv-provision}

HC=$(security find-generic-password -s entire-push-check:healthcheck-url -w 2>/dev/null || true)
[[ -n "$HC" ]] || { echo "entire-push-check:healthcheck-url not in Keychain" >&2; exit 1; }
HC_DOOR=$(security find-generic-password -s lmstudio-door:healthcheck-url -w 2>/dev/null || true)
[[ -n "$HC_DOOR" ]] || { echo "lmstudio-door:healthcheck-url not in Keychain" >&2; exit 1; }

scp -q -o ConnectTimeout=30 -o BatchMode=yes \
    "$HERE/entire-push-check-job" \
    "$HERE/entire-push-check.service" "$HERE/entire-push-check.timer" \
    "$HERE/lmstudio-door-job" \
    "$HERE/lmstudio-door.service" "$HERE/lmstudio-door.timer" \
    "$VM:/tmp/"

printf 'HC_URL=%s\nHC_DOOR_URL=%s\n' "$HC" "$HC_DOOR" | ssh -o ConnectTimeout=30 -o BatchMode=yes "$VM" '
    set -euo pipefail; umask 077
    mkdir -p ~/.local/bin ~/.config/entire-push-check ~/.config/lmstudio-door
    # stdin: line 1 entire-push-check URL, line 2 lmstudio-door URL -- one env file each.
    IFS= read -r line1; IFS= read -r line2
    printf "%s\n" "$line1" > ~/.config/entire-push-check/env
    printf "HC_URL=%s\n" "${line2#HC_DOOR_URL=}" > ~/.config/lmstudio-door/env
    chmod 0600 ~/.config/entire-push-check/env ~/.config/lmstudio-door/env
    install -m 0755 /tmp/entire-push-check-job ~/.local/bin/entire-push-check-job
    install -m 0755 /tmp/lmstudio-door-job ~/.local/bin/lmstudio-door-job
    changed=0
    for u in entire-push-check.service entire-push-check.timer lmstudio-door.service lmstudio-door.timer; do
        if ! sudo cmp -s "/tmp/$u" "/etc/systemd/system/$u"; then
            sudo install -m 0644 "/tmp/$u" "/etc/systemd/system/$u"; changed=1
        fi
    done
    if (( changed )); then sudo systemctl daemon-reload; fi
    sudo systemctl enable --now entire-push-check.timer lmstudio-door.timer >/dev/null
    rm -f /tmp/entire-push-check-job /tmp/entire-push-check.service /tmp/entire-push-check.timer \
          /tmp/lmstudio-door-job /tmp/lmstudio-door.service /tmp/lmstudio-door.timer
    for t in entire-push-check.timer lmstudio-door.timer; do
        echo "  $t next run: $(systemctl list-timers "$t" --no-pager 2>/dev/null | awk "NR==2{print \$1, \$2, \$3}")"
    done
'

#!/usr/bin/env bash
# Deploy the collector-side coverage check to iv-agentsview from the mini.
# iv-agentsview is exeslim (no dotfiles clone, no agent harness), so the
# script, its systemd units and the healthchecks.io ping URL (mini Keychain
# agentsview-coverage:healthcheck-url) are pushed over SSH. Idempotent.
# One SSH connection at a time — exe.dev drops parallel SYNs from one IP.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
VM=${1:-iv-agentsview.exe.xyz}
HC=$(security find-generic-password -s agentsview-coverage:healthcheck-url -w 2>/dev/null || true)
[[ -n "$HC" ]] || { echo "agentsview-coverage:healthcheck-url not in Keychain" >&2; exit 1; }

scp -q -o ConnectTimeout=30 -o BatchMode=yes \
    "$HERE/agentsview-coverage" "$HERE/agentsview-coverage.service" "$HERE/agentsview-coverage.timer" \
    "$VM:/tmp/"
printf 'HC_URL=%s\n' "$HC" | ssh -o ConnectTimeout=30 -o BatchMode=yes "$VM" '
    set -euo pipefail; umask 077
    mkdir -p ~/.local/bin ~/.config/agentsview-coverage
    cat > ~/.config/agentsview-coverage/env
    install -m 0755 /tmp/agentsview-coverage ~/.local/bin/agentsview-coverage
    sudo install -m 0644 /tmp/agentsview-coverage.service /tmp/agentsview-coverage.timer /etc/systemd/system/
    rm -f /tmp/agentsview-coverage /tmp/agentsview-coverage.service /tmp/agentsview-coverage.timer
    sudo systemctl daemon-reload
    sudo systemctl enable --now agentsview-coverage.timer
    systemctl list-timers agentsview-coverage.timer --no-pager | head -2
'

#!/usr/bin/env bash
# Deploy the collector-side jobs to iv-agentsview from the mini. iv-agentsview
# is exeslim (no dotfiles clone, no agent harness), so the scripts, the systemd
# units and the healthchecks.io ping URL (mini Keychain
# agentsview-coverage:healthcheck-url) are pushed over SSH. Idempotent: the
# collector is restarted only when its unit file changed.
# One SSH connection at a time — exe.dev drops parallel SYNs from one IP.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
VM=${1:-iv-agentsview.exe.xyz}
HC=$(security find-generic-password -s agentsview-coverage:healthcheck-url -w 2>/dev/null || true)
[[ -n "$HC" ]] || { echo "agentsview-coverage:healthcheck-url not in Keychain" >&2; exit 1; }

scp -q -o ConnectTimeout=30 -o BatchMode=yes \
    "$HERE/agentsview-coverage" "$HERE/agentsview-reconcile" \
    "$HERE/agentsview.service" "$HERE/agentsview-coverage.service" "$HERE/agentsview-coverage.timer" \
    "$VM:/tmp/"
printf 'HC_URL=%s\n' "$HC" | ssh -o ConnectTimeout=30 -o BatchMode=yes "$VM" '
    set -euo pipefail; umask 077
    mkdir -p ~/.local/bin ~/.config/agentsview-coverage
    cat > ~/.config/agentsview-coverage/env
    install -m 0755 /tmp/agentsview-coverage ~/.local/bin/agentsview-coverage
    install -m 0755 /tmp/agentsview-reconcile ~/.local/bin/agentsview-reconcile
    sudo install -m 0644 /tmp/agentsview-coverage.service /tmp/agentsview-coverage.timer /etc/systemd/system/
    restart=0
    if ! sudo cmp -s /tmp/agentsview.service /etc/systemd/system/agentsview.service; then
        sudo install -m 0644 /tmp/agentsview.service /etc/systemd/system/agentsview.service; restart=1
    fi
    # No bearer for the collector anywhere: the unit passes no --require-auth,
    # and the config must not re-enable it (require_auth) or hold a stale token.
    if grep -qE "^[[:space:]]*(auth_token|require_auth)[[:space:]]*=" ~/.agentsview/config.toml; then
        sed -i -E "/^[[:space:]]*(auth_token|require_auth)[[:space:]]*=/d" ~/.agentsview/config.toml; restart=1
    fi
    rm -f /tmp/agentsview-coverage /tmp/agentsview-reconcile /tmp/agentsview.service /tmp/agentsview-coverage.service /tmp/agentsview-coverage.timer
    sudo systemctl daemon-reload
    sudo systemctl enable --now agentsview-coverage.timer
    [[ $restart -eq 0 ]] || { sudo systemctl restart agentsview; sleep 3; }
    echo "collector: $(systemctl is-active agentsview)  timer: $(systemctl is-active agentsview-coverage.timer)"
'

#!/usr/bin/env bash
# Deploy the nginx relay config to iv-personal-mcp-relay from the mini.
# Bare exeslim VM (no dotfiles clone, no agent harness); config pushed over the
# exe.dev SSH endpoint (Tailscale SSH has no SFTP). No secrets to render.
# Idempotent: nginx is reloaded only when the file differs. One SSH connection
# at a time — exe.dev drops parallel SYNs from one IP.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
VM=${1:-iv-personal-mcp-relay.exe.xyz}
ssh -o ConnectTimeout=30 -o BatchMode=yes "$VM" '
    set -euo pipefail; umask 077
    cat > /tmp/relay.nginx
    command -v nginx >/dev/null || { sudo apt-get update -qq && sudo apt-get install -y -qq nginx-light >/dev/null; }
    if sudo cmp -s /tmp/relay.nginx /etc/nginx/sites-available/personal-mcp-relay 2>/dev/null; then
        echo "relay.nginx unchanged"
    else
        sudo install -m 0644 -o root -g root /tmp/relay.nginx /etc/nginx/sites-available/personal-mcp-relay
        sudo ln -sf /etc/nginx/sites-available/personal-mcp-relay /etc/nginx/sites-enabled/personal-mcp-relay
        sudo rm -f /etc/nginx/sites-enabled/default
        sudo nginx -t
        sudo systemctl reload nginx
        echo "relay.nginx updated, nginx reloaded"
    fi
    rm -f /tmp/relay.nginx
    sudo systemctl enable nginx >/dev/null 2>&1 || true
' < "$HERE/relay.nginx"

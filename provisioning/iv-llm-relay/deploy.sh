#!/usr/bin/env bash
# Deploy the nginx relay config to iv-llm-relay from the mini.
# iv-llm-relay is bare exeslim (no dotfiles clone, no agent harness), so the
# config is pushed over SSH, with the shared header key substituted from
# 1Password at deploy time — the key never lives in this repo. Idempotent:
# nginx is reloaded only when the rendered config differs from the installed
# one. Uses the exe.dev SSH endpoint: Tailscale SSH has no SFTP, so scp over
# the tailnet fails. One SSH connection at a time — exe.dev drops parallel
# SYNs from one IP. Design and runbooks: agent_docs/llm-relay.md.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
VM=${1:-iv-llm-relay.exe.xyz}
# `op read` rejects the parentheses in the item title; `op item get` does not.
KEY=$(op item get 'LLM relay header key (iv-llm-relay)' --vault Employee --fields label=credential --reveal 2>/dev/null || true)
[[ -n "$KEY" ]] || { echo "LLM relay header key not readable from 1Password (op read)" >&2; exit 1; }

sed "s|__KEY__|$KEY|" "$HERE/relay.nginx" | ssh -o ConnectTimeout=30 -o BatchMode=yes "$VM" '
    set -euo pipefail; umask 077
    cat > /tmp/relay.nginx
    command -v nginx >/dev/null || { sudo apt-get update -qq && sudo apt-get install -y -qq nginx-light >/dev/null; }
    if sudo cmp -s /tmp/relay.nginx /etc/nginx/sites-available/relay 2>/dev/null; then
        echo "relay.nginx unchanged"
    else
        sudo install -m 0600 -o root -g root /tmp/relay.nginx /etc/nginx/sites-available/relay
        sudo ln -sf /etc/nginx/sites-available/relay /etc/nginx/sites-enabled/relay
        sudo rm -f /etc/nginx/sites-enabled/default
        sudo nginx -t
        sudo systemctl reload nginx
        echo "relay.nginx updated, nginx reloaded"
    fi
    rm -f /tmp/relay.nginx
    sudo systemctl enable nginx >/dev/null 2>&1 || true
'
# Gate check from here: the public URL must refuse a key-less request.
code=$(curl -s -o /dev/null --max-time 20 -w '%{http_code}' https://iv-llm-relay.exe.xyz/mini/v1/models || true)
[[ "$code" == "403" ]] && echo "gate ok (403 without key)" || { echo "gate check FAILED: got $code without key" >&2; exit 1; }

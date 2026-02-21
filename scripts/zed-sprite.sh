#!/bin/bash
set -euo pipefail

# Sets up SSH on a Sprite for Zed remote development.
# Installs openssh-server, copies your SSH public key, and starts sshd.
# Connect via: sprite proxy -s <name> 2222:22 & zed ssh://sprite@localhost:2222/home/sprite
#
# Usage: ./setup-sprite-ssh.sh [-o org] <sprite-name>

# --- Args ---
ORG=""
SPRITE_NAME=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|--org) ORG="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [-o org] <sprite-name>"
            echo ""
            echo "Sets up SSH on a Sprite for Zed remote development."
            echo "Installs openssh-server, copies your SSH key, starts sshd."
            echo ""
            echo "Options:"
            echo "  -o, --org    Sprite organization"
            echo ""
            echo "After setup, connect with:"
            echo "  sprite proxy -s <name> 2222:22   # in a separate terminal"
            echo "  zed ssh://sprite@localhost:2222/home/sprite"
            exit 0
            ;;
        -*) echo "Unknown flag: $1"; exit 1 ;;
        *)  SPRITE_NAME="$1"; shift ;;
    esac
done

if [[ -z "$SPRITE_NAME" ]]; then
    echo "Error: sprite name required"
    echo "Usage: $0 [-o org] <sprite-name>"
    exit 1
fi

SPRITE_EXEC=(sprite exec -s "$SPRITE_NAME")
[[ -n "$ORG" ]] && SPRITE_EXEC+=(-o "$ORG")

# --- Resolve SSH public key ---
SSH_PUBKEY=$(ssh-add -L 2>/dev/null | head -1) || true

if [[ -z "$SSH_PUBKEY" ]]; then
    echo "Error: no SSH public keys found (ssh-add -L returned nothing)."
    echo "Is your SSH agent running? (1Password SSH agent, ssh-agent, etc.)"
    exit 1
fi

echo "=== Setting up SSH on sprite: $SPRITE_NAME ==="
echo ""

# --- Step 1: Install openssh-server ---
echo "[1/3] Installing openssh-server..."
"${SPRITE_EXEC[@]}" -- bash -c '
    if command -v sshd &>/dev/null; then
        echo "  Already installed"
    else
        export DEBIAN_FRONTEND=noninteractive
        sudo apt-get update -qq && sudo apt-get install -y -qq openssh-server
    fi
    sudo mkdir -p /run/sshd
    sudo tee /etc/ssh/sshd_config.d/sprite.conf > /dev/null <<SSHEOF
PasswordAuthentication no
PubkeyAuthentication yes
PermitRootLogin no
SSHEOF
    echo "  Configured (key-only auth, no root login)"
'

# --- Step 2: Copy SSH public key ---
echo "[2/3] Copying SSH public key..."
"${SPRITE_EXEC[@]}" --env "SSH_PUBKEY=$SSH_PUBKEY" -- bash -c '
    mkdir -p ~/.ssh && chmod 700 ~/.ssh
    touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
    if grep -qF "$SSH_PUBKEY" ~/.ssh/authorized_keys 2>/dev/null; then
        echo "  Key already authorized"
    else
        echo "$SSH_PUBKEY" >> ~/.ssh/authorized_keys
        echo "  Key added"
    fi
'

# --- Step 3: Start sshd service ---
echo "[3/3] Starting sshd service..."
"${SPRITE_EXEC[@]}" -- bash -c '
    sprite_api() { sprite-env curl "$@"; }
    if sprite_api /v1/services/sshd 2>/dev/null | grep -q "running"; then
        echo "  Already running"
    else
        sprite_api -X PUT "/v1/services/sshd?duration=3s" -d "{
            \"cmd\": \"/usr/sbin/sshd\",
            \"args\": [\"-D\", \"-e\"]
        }"
        sleep 2
        echo "  Started"
    fi
'

echo ""
echo "=== Sprite SSH ready ==="
echo ""

# --- Start proxy and open Zed ---
LOCAL_PORT=2222
PROXY_ARGS=(-s "$SPRITE_NAME")
[[ -n "$ORG" ]] && PROXY_ARGS+=(-o "$ORG")
PROXY_ARGS+=("$LOCAL_PORT:22")

# Kill any existing proxy on this port
lsof -ti :"$LOCAL_PORT" 2>/dev/null | xargs kill 2>/dev/null || true
sleep 1

echo "Starting proxy (localhost:$LOCAL_PORT -> $SPRITE_NAME:22)..."
sprite proxy "${PROXY_ARGS[@]}" &>/dev/null &
PROXY_PID=$!
sleep 2

if kill -0 "$PROXY_PID" 2>/dev/null; then
    echo "  Proxy running (pid $PROXY_PID)"
    echo ""
    echo "Opening Zed..."
    zed ssh://sprite@localhost:$LOCAL_PORT/home/sprite
    echo ""
    echo "  Proxy will keep running in the background (pid $PROXY_PID)."
    echo "  Stop it with: kill $PROXY_PID"
else
    echo "  Proxy failed to start."
    echo "  Try manually: sprite proxy -s $SPRITE_NAME $LOCAL_PORT:22"
    exit 1
fi

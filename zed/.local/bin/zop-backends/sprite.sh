#!/bin/bash
# zop backend: Fly.io Sprite (remote)
# Requires: sprite CLI, SSH agent with keys

backend_available() { command -v sprite &>/dev/null; }

SPRITE_LOCAL_PORT=2222

_sprite_exec() {
    local args=(sprite exec -s "$MACHINE")
    [[ -n "${ORG:-}" ]] && args+=(-o "$ORG")
    args+=("$@")
    "${args[@]}"
}

backend_list() {
    sprite list 2>/dev/null | awk 'NF{print $1}'
}

backend_create() {
    local name
    printf "Sprite name: " >&2
    read -r name
    [[ -z "$name" ]] && die "Name required"
    local args=(sprite create --skip-console "$name")
    [[ -n "${ORG:-}" ]] && args+=(-o "$ORG")
    "${args[@]}" >&2
    MACHINE="$name"
}

backend_start() {
    [[ -z "$MACHINE" ]] && die "No sprite specified"
    # Sprites auto-wake on connection
}

backend_ensure_ssh() {
    local pubkey
    pubkey=$(ssh_pubkey)

    echo "Setting up SSH on sprite: $MACHINE" >&2

    # Install openssh-server
    echo "  [1/3] Installing openssh-server..." >&2
    _sprite_exec -- bash -c '
        if command -v sshd &>/dev/null; then
            echo "    Already installed" >&2
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
        echo "    Configured" >&2
    '

    # Copy SSH public key
    echo "  [2/3] Copying SSH public key..." >&2
    _sprite_exec --env "SSH_PUBKEY=$pubkey" -- bash -c '
        mkdir -p ~/.ssh && chmod 700 ~/.ssh
        touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
        if grep -qF "$SSH_PUBKEY" ~/.ssh/authorized_keys 2>/dev/null; then
            echo "    Key already authorized" >&2
        else
            echo "$SSH_PUBKEY" >> ~/.ssh/authorized_keys
            echo "    Key added" >&2
        fi
    '

    # Start sshd service
    echo "  [3/3] Starting sshd service..." >&2
    _sprite_exec -- bash -c '
        sprite_api() { sprite-env curl "$@"; }
        if sprite_api /v1/services/sshd 2>/dev/null | grep -q "running"; then
            echo "    Already running" >&2
        else
            sprite_api -X PUT "/v1/services/sshd?duration=3s" -d "{
                \"cmd\": \"/usr/sbin/sshd\",
                \"args\": [\"-D\", \"-e\"]
            }"
            sleep 2
            echo "    Started" >&2
        fi
    '

    # Start local proxy
    echo "  Starting proxy (localhost:$SPRITE_LOCAL_PORT -> $MACHINE:22)..." >&2
    lsof -ti :"$SPRITE_LOCAL_PORT" 2>/dev/null | xargs kill 2>/dev/null || true
    sleep 1

    local proxy_args=(-s "$MACHINE")
    [[ -n "${ORG:-}" ]] && proxy_args+=(-o "$ORG")
    proxy_args+=("$SPRITE_LOCAL_PORT:22")

    sprite proxy "${proxy_args[@]}" &>/dev/null &
    local proxy_pid=$!
    sleep 2

    if ! kill -0 "$proxy_pid" 2>/dev/null; then
        die "Sprite proxy failed to start. Try: sprite proxy -s $MACHINE $SPRITE_LOCAL_PORT:22"
    fi
    echo "  Proxy running (pid $proxy_pid)" >&2

    echo "sprite@localhost:$SPRITE_LOCAL_PORT"
}

backend_list_projects() {
    remote_exec "find ~ -mindepth 1 -maxdepth 1 -type d ! -name '.*' 2>/dev/null" || true
}

backend_clone_project() {
    local repo="$1"
    remote_exec "git clone 'git@github.com:${repo}.git' ~/${repo##*/}" >&2
    echo "~/${repo##*/}"
}

backend_home() {
    echo "~"
}

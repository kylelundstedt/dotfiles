#!/bin/bash
# zop backend: Fly.io Sprite (remote)
# Requires: sprite CLI, SSH agent with keys

backend_available() { command -v sprite &>/dev/null; }

# Pick a random high port to avoid collisions between concurrent sprite proxies
_find_free_port() {
    local port
    while true; do
        port=$((RANDOM % 16384 + 49152))
        if ! lsof -ti :"$port" &>/dev/null; then
            echo "$port"
            return
        fi
    done
}
SPRITE_LOCAL_PORT=""

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
    printf "Name: " >&2
    read -r name
    if [[ -z "$name" ]]; then die "Name required"; fi
    local args=(sprite create --skip-console "$name")
    [[ -n "${ORG:-}" ]] && args+=(-o "$ORG")
    "${args[@]}" >&2
    MACHINE="$name"
    echo "Created $MACHINE (sprite)" >&2
}

backend_start() {
    if [[ -z "$MACHINE" ]]; then die "No sprite specified"; fi
    # Sprites auto-wake on connection
}

backend_ensure_ssh() {
    local pubkey target_user="klundstedt"
    pubkey=$(ssh_pubkey)

    echo "Setting up SSH on sprite: $MACHINE" >&2

    # Install openssh-server
    echo "  [1/4] Installing packages..." >&2
    _sprite_exec -- bash -c '
        if command -v sshd &>/dev/null; then
            echo "    Already installed" >&2
        else
            export DEBIAN_FRONTEND=noninteractive
            sudo apt-get update -qq && sudo apt-get install -y -qq openssh-server
        fi
        sudo mkdir -p /run/sshd
    ' >&2

    # Create non-root user with passwordless sudo
    echo "  [2/4] Creating user $target_user..." >&2
    _sprite_exec --env "U=$target_user" -- bash -c '
        if id "$U" >/dev/null 2>&1; then
            echo "    Already exists" >&2
        else
            sudo useradd -m -s /bin/bash "$U"
            echo "$U ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/"$U" >/dev/null
            sudo chmod 440 /etc/sudoers.d/"$U"
            echo "    Created" >&2
        fi
    ' >&2

    # Copy SSH public key to target user + configure sshd
    echo "  [3/4] Configuring SSH..." >&2
    _sprite_exec --env "SSH_PUBKEY=$pubkey" --env "U=$target_user" -- bash -c '
        home=$(eval echo "~$U")
        sudo mkdir -p "$home/.ssh" && sudo chmod 700 "$home/.ssh"
        sudo touch "$home/.ssh/authorized_keys" && sudo chmod 600 "$home/.ssh/authorized_keys"
        sudo chown -R "$U:$U" "$home/.ssh"
        if sudo grep -qF "$SSH_PUBKEY" "$home/.ssh/authorized_keys" 2>/dev/null; then
            echo "    Key already authorized" >&2
        else
            echo "$SSH_PUBKEY" | sudo tee -a "$home/.ssh/authorized_keys" >/dev/null
            sudo chown "$U:$U" "$home/.ssh/authorized_keys"
            echo "    Key added" >&2
        fi
        sudo tee /etc/ssh/sshd_config.d/sprite.conf > /dev/null <<SSHEOF
PasswordAuthentication no
PubkeyAuthentication yes
PermitRootLogin no
SSHEOF
        echo "    Configured" >&2
    ' >&2

    # Start sshd service
    echo "  [4/4] Starting sshd service..." >&2
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
    ' >&2

    # Start local proxy on a free port
    SPRITE_LOCAL_PORT=$(_find_free_port)
    echo "  Starting proxy (localhost:$SPRITE_LOCAL_PORT -> $MACHINE:22)..." >&2

    local proxy_args=(-s "$MACHINE")
    [[ -n "${ORG:-}" ]] && proxy_args+=(-o "$ORG")
    proxy_args+=("$SPRITE_LOCAL_PORT:22")

    nohup sprite proxy "${proxy_args[@]}" &>/dev/null &
    local proxy_pid=$!
    disown "$proxy_pid"
    sleep 2

    if ! kill -0 "$proxy_pid" 2>/dev/null; then
        die "Sprite proxy failed to start. Try: sprite proxy -s $MACHINE $SPRITE_LOCAL_PORT:22"
    fi
    echo "  Proxy running (pid $proxy_pid)" >&2

    echo "${target_user}@localhost:$SPRITE_LOCAL_PORT"
}

backend_list_projects() {
    remote_exec "find ~ -mindepth 1 -maxdepth 1 -type d ! -name '.*' ! -name 'dotfiles' 2>/dev/null" || true
}

backend_clone_project() {
    local repo="$1"
    remote_exec "git clone 'git@github.com:${repo}.git' ~/${repo##*/}" >&2
    echo "~/${repo##*/}"
}

backend_home() {
    echo "~"
}

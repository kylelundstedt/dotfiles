#!/bin/bash
# zop backend: Apple Container (macOS 26+)
# Requires: container CLI (Apple silicon, macOS Tahoe)
# Installs openssh-server for SSH access — containers don't expose SSH by default.

backend_list() {
    container list 2>/dev/null | tail -n +2 | awk '{print $1}'
}

backend_start() {
    local state
    state=$(container list 2>/dev/null | awk -v m="$MACHINE" '$1==m{print $2}') || true
    if [[ "$state" != "running" ]]; then
        echo "Starting container: $MACHINE..." >&2
        container start "$MACHINE" >/dev/null
        sleep 3
    fi
}

backend_ensure_ssh() {
    local pubkey
    pubkey=$(ssh_pubkey)

    echo "Setting up SSH on container: $MACHINE" >&2

    # Install openssh-server
    echo "  [1/3] Installing openssh-server..." >&2
    container exec "$MACHINE" sh -c '
        if command -v sshd >/dev/null 2>&1; then
            echo "    Already installed" >&2
        else
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq >/dev/null && apt-get install -y -qq openssh-server >/dev/null
        fi
        mkdir -p /run/sshd
        cat > /etc/ssh/sshd_config.d/zop.conf <<SSHEOF
PasswordAuthentication no
PubkeyAuthentication yes
PermitRootLogin prohibit-password
SSHEOF
        echo "    Configured" >&2
    ' >/dev/null

    # Copy SSH public key
    echo "  [2/3] Copying SSH public key..." >&2
    container exec -e "SSH_PUBKEY=$pubkey" "$MACHINE" sh -c '
        mkdir -p ~/.ssh && chmod 700 ~/.ssh
        touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
        if grep -qF "$SSH_PUBKEY" ~/.ssh/authorized_keys 2>/dev/null; then
            echo "    Key already authorized" >&2
        else
            echo "$SSH_PUBKEY" >> ~/.ssh/authorized_keys
            echo "    Key added" >&2
        fi
    ' >/dev/null

    # Start sshd (--detach keeps it alive after exec exits)
    echo "  [3/3] Starting sshd..." >&2
    local listening
    listening=$(container exec "$MACHINE" bash -c 'echo >/dev/tcp/127.0.0.1/22 2>/dev/null && echo yes || echo no' 2>/dev/null) || true
    if [[ "$listening" == "yes" ]]; then
        echo "    Already running" >&2
    else
        container exec "$MACHINE" sh -c 'kill $(pgrep sshd) 2>/dev/null; mkdir -p /run/sshd' 2>/dev/null
        container exec --detach "$MACHINE" /usr/sbin/sshd -D -e >/dev/null 2>/dev/null
        sleep 2
        echo "    Started" >&2
    fi

    # Get container IP
    local ip
    ip=$(container exec "$MACHINE" hostname -I 2>/dev/null | awk '{print $1}')
    [[ -z "$ip" ]] && die "Could not determine container IP"
    echo "  Container IP: $ip" >&2

    echo "root@${ip}"
}

backend_list_projects() {
    remote_exec "find ~ -mindepth 1 -maxdepth 1 -type d ! -name '.*' 2>/dev/null" || true
}

backend_home() {
    echo "~"
}

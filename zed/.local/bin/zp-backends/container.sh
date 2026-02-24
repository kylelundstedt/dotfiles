#!/bin/bash
# zp backend: Apple Container (macOS 26+)
# Requires: container CLI (Apple silicon, macOS Tahoe)
# Installs openssh-server for SSH access — containers don't expose SSH by default.

backend_available() { command -v container &>/dev/null; }

backend_list() {
    container list 2>/dev/null | tail -n +2 | awk '{print $1}'
}

backend_create() {
    local name="$1"
    [[ -z "$name" ]] && die "Name required"
    container run --name "$name" --cpus 4 --memory 4G ubuntu:25.04 sleep infinity >&2 &
    sleep 3
    MACHINE="$name"
    echo "Created $MACHINE (container)" >&2
}

backend_start() {
    if [[ -z "$MACHINE" ]]; then die "No container specified"; fi
    local state
    state=$(container list --all 2>/dev/null | awk -v m="$MACHINE" '$1==m{print $5}') || true
    if [[ "$state" == "running" ]]; then
        return
    fi
    echo "Starting container: $MACHINE..." >&2
    container start "$MACHINE" >/dev/null
    sleep 3
}

backend_ensure_ssh() {
    local pubkey target_user="klundstedt"
    pubkey=$(ssh_pubkey)

    echo "Setting up SSH on container: $MACHINE" >&2

    # Install openssh-server + git + sudo
    echo "  [1/4] Installing packages..." >&2
    container exec "$MACHINE" sh -c '
        if command -v sshd >/dev/null 2>&1 && command -v git >/dev/null 2>&1 && command -v sudo >/dev/null 2>&1; then
            echo "    Already installed" >&2
        else
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq >/dev/null && apt-get install -y -qq openssh-server git sudo >/dev/null
        fi
        mkdir -p /run/sshd
    ' >/dev/null

    # Create non-root user with passwordless sudo
    echo "  [2/4] Creating user $target_user..." >&2
    container exec -e "U=$target_user" "$MACHINE" sh -c '
        if id "$U" >/dev/null 2>&1; then
            echo "    Already exists" >&2
        else
            useradd -m -s /bin/bash "$U"
            echo "$U ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/"$U"
            chmod 440 /etc/sudoers.d/"$U"
            echo "    Created" >&2
        fi
    ' >/dev/null

    # Copy SSH public key to target user + configure sshd
    echo "  [3/4] Configuring SSH..." >&2
    container exec -e "SSH_PUBKEY=$pubkey" -e "U=$target_user" "$MACHINE" sh -c '
        home=$(eval echo "~$U")
        mkdir -p "$home/.ssh" && chmod 700 "$home/.ssh"
        touch "$home/.ssh/authorized_keys" && chmod 600 "$home/.ssh/authorized_keys"
        chown -R "$U:$U" "$home/.ssh"
        if grep -qF "$SSH_PUBKEY" "$home/.ssh/authorized_keys" 2>/dev/null; then
            echo "    Key already authorized" >&2
        else
            echo "$SSH_PUBKEY" >> "$home/.ssh/authorized_keys"
            chown "$U:$U" "$home/.ssh/authorized_keys"
            echo "    Key added" >&2
        fi
        cat > /etc/ssh/sshd_config.d/zp.conf <<SSHEOF
PasswordAuthentication no
PubkeyAuthentication yes
PermitRootLogin no
SSHEOF
        echo "    Configured" >&2
    ' >/dev/null

    # Start sshd (--detach keeps it alive after exec exits)
    echo "  [4/4] Starting sshd..." >&2
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

    # Get container IP and write SSH config alias
    local ip
    ip=$(container exec "$MACHINE" hostname -I 2>/dev/null | awk '{print $1}')
    [[ -z "$ip" ]] && die "Could not determine container IP"
    echo "  Container IP: $ip" >&2

    _write_ssh_config "$MACHINE" "$ip" "$target_user"

    echo "$MACHINE"
}

backend_exec() {
    container exec "$MACHINE" bash -c "$1"
}

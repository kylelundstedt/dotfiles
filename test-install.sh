#!/bin/bash
# Test install.sh across the same backends zp uses.
# Usage: ./test-install.sh [container|sprite|all]
#   container — Apple Container (klundstedt user, sudo available)
#   sprite    — Fly.io Sprite (klundstedt user, sudo available)
#   all       — both (default)

set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")" && pwd)"
PASS=0
FAIL=0

log_pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
log_fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# Verification script injected into remote environments
read -r -d '' VERIFY_SCRIPT << 'VERIFY' || true
export PATH=$HOME/.local/bin:$HOME/.atuin/bin:$PATH
eval "$(fnm env 2>/dev/null)" || true

for cmd in starship uv atuin zoxide direnv fnm bat fzf rg jq yq gh duckdb carapace node claude codex op; do
    if command -v $cmd >/dev/null 2>&1; then echo "OK $cmd"; else echo "MISSING $cmd"; fi
done

# SSH multiplexing
if grep -q "Host github.com" ~/.ssh/config 2>/dev/null; then echo "OK ssh-mux"; else echo "MISSING ssh-mux"; fi

# Git OS include
if [ -f ~/.gitconfig_os_local ]; then echo "OK git-os-include"; else echo "MISSING git-os-include"; fi

# Stow symlinks
for f in .zshrc .config/starship.toml; do
    if [ -L "$HOME/$f" ]; then echo "OK stow:$f"; else echo "MISSING stow:$f"; fi
done

# MCP servers registered in Claude (remote HTTP transport)
if command -v claude >/dev/null 2>&1; then
    mcp_list=$(claude mcp list 2>/dev/null || true)
    for srv in motherduck tigris; do
        if echo "$mcp_list" | grep -q "$srv"; then echo "OK mcp:$srv"; else echo "MISSING mcp:$srv"; fi
    done
    # GitHub servers require 1Password
    if command -v op >/dev/null 2>&1 && op account list 2>/dev/null | grep -q .; then
        for srv in github-home github-work; do
            if echo "$mcp_list" | grep -q "$srv"; then echo "OK mcp:$srv"; else echo "MISSING mcp:$srv"; fi
        done
    fi
fi

# Skills directories
for skill in bootstrap-project data-pipelines sprites mviz find-skills; do
    if [ -d "$HOME/.claude/skills/$skill" ]; then echo "OK skill:$skill"; else echo "MISSING skill:$skill"; fi
done
VERIFY

parse_results() {
    local prefix="$1" output="$2"
    while IFS= read -r line; do
        case "$line" in
            OK*)      log_pass "$prefix: ${line#OK }" ;;
            MISSING*) log_fail "$prefix: ${line#MISSING }" ;;
        esac
    done <<< "$output"
}

# --- Apple Container (klundstedt user, sudo available) ---
test_container() {
    if ! command -v container >/dev/null 2>&1; then
        echo "container CLI not found — skipping container test."
        return 0
    fi

    local name="test-dotfiles-ct-$$"
    local target_user="klundstedt"
    echo "=== Container test (non-root, sudo available) ==="
    container run --name "$name" ubuntu:25.04 sleep infinity &
    sleep 5

    echo ""
    echo "--- Setting up user and SSH ---"
    container exec "$name" bash -c "
        apt-get update -qq && apt-get install -y -qq git curl openssh-server sudo >/dev/null
        mkdir -p /run/sshd
        useradd -m -s /bin/bash $target_user
        echo '$target_user ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/$target_user
        chmod 440 /etc/sudoers.d/$target_user
    "
    # SSH key goes to the non-root user
    local pubkey
    pubkey=$(ssh-add -L 2>/dev/null | head -1)
    container exec -e "K=$pubkey" -e "U=$target_user" "$name" bash -c '
        home=$(eval echo "~$U")
        mkdir -p "$home/.ssh" && chmod 700 "$home/.ssh"
        echo "$K" >> "$home/.ssh/authorized_keys"
        chmod 600 "$home/.ssh/authorized_keys"
        chown -R "$U:$U" "$home/.ssh"
    '
    container exec "$name" bash -c '
        cat > /etc/ssh/sshd_config.d/zp.conf <<SSHEOF
PasswordAuthentication no
PubkeyAuthentication yes
PermitRootLogin no
SSHEOF
    '
    container exec --detach "$name" /usr/sbin/sshd -D -e >/dev/null 2>/dev/null
    sleep 2
    local ct_ip
    ct_ip=$(container exec "$name" hostname -I 2>/dev/null | awk '{print $1}')
    local ssh_target="${target_user}@${ct_ip}"

    echo ""
    echo "--- Installing as $target_user ---"
    # Clone from GitHub then overlay local changes via tar+ssh
    ssh -o StrictHostKeyChecking=no "$ssh_target" "git clone https://github.com/kylelundstedt/dotfiles ~/dotfiles 2>/dev/null || true"
    tar -C "$DOTFILES_DIR" --exclude=.git -cf - . | ssh -o StrictHostKeyChecking=no "$ssh_target" "tar -C ~/dotfiles -xf -"
    ssh -o StrictHostKeyChecking=no "$ssh_target" "cd ~/dotfiles && bash install.sh --no-prompt 2>&1" || {
        log_fail "container: install.sh"
        container stop "$name" 2>/dev/null; container rm "$name" 2>/dev/null || true
        return
    }
    log_pass "container: install.sh"

    echo ""
    echo "--- Verifying ---"
    parse_results "container" "$(ssh -o StrictHostKeyChecking=no "$ssh_target" "$VERIFY_SCRIPT" 2>&1)"

    echo ""
    echo "--- Tearing down container ---"
    container stop "$name" 2>/dev/null; container rm "$name" 2>/dev/null || true
}

# --- Sprite (klundstedt user, sudo available) ---
test_sprite() {
    if ! command -v sprite >/dev/null 2>&1; then
        echo "sprite CLI not found — skipping sprite test."
        return 0
    fi

    local name="test-dotfiles-sp-$$"
    local target_user="klundstedt"
    echo "=== Sprite test (non-root, sudo available) ==="
    sprite create --skip-console "$name"

    echo ""
    echo "--- Setting up user ---"
    # Create klundstedt user (sprite exec runs as platform default user with sudo)
    sprite exec -s "$name" -- bash -c "
        sudo apt-get update -qq && sudo apt-get install -y -qq git curl >/dev/null
        sudo useradd -m -s /bin/bash $target_user
        echo '$target_user ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/$target_user >/dev/null
        sudo chmod 440 /etc/sudoers.d/$target_user
    "

    echo ""
    echo "--- Installing as $target_user ---"
    # Copy local working tree and run install as klundstedt
    tar -C "$DOTFILES_DIR" -cf - --exclude=.git . | sprite exec -s "$name" -- bash -c "
        sudo mkdir -p /home/$target_user/dotfiles
        sudo tar -C /home/$target_user/dotfiles -xf -
        sudo chown -R $target_user:$target_user /home/$target_user/dotfiles
        cd /home/$target_user/dotfiles && sudo git init -q
    "
    sprite exec -s "$name" -- bash -c "
        sudo -u $target_user bash -c 'cd ~/dotfiles && bash install.sh --no-prompt 2>&1'
    " || {
        log_fail "sprite: install.sh"
        sprite destroy -s "$name" --force 2>/dev/null || true
        return
    }
    log_pass "sprite: install.sh"

    echo ""
    echo "--- Verifying ---"
    parse_results "sprite" "$(sprite exec -s "$name" -- bash -c "sudo -u $target_user bash -c '$VERIFY_SCRIPT'" 2>&1)"

    echo ""
    echo "--- Tearing down sprite ---"
    sprite destroy -s "$name" --force 2>/dev/null || true
}

# --- Dispatch ---
mode="${1:-all}"
case "$mode" in
    container) test_container ;;
    sprite)    test_sprite ;;
    all)       test_container; test_sprite ;;
    *)         echo "Usage: $0 [container|sprite|all]"; exit 1 ;;
esac

TOTAL=$((PASS + FAIL))
echo ""
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
[[ $FAIL -gt 0 ]] && exit 1
exit 0

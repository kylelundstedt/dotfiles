#!/bin/bash
# Test install.sh across VM backends.
# Usage: ./test-install.sh [container|sprite|exe|all]
#   container — Apple Container (klundstedt user, sudo available)
#   sprite    — Fly.io Sprite (klundstedt user, sudo available)
#   exe       — exe.dev VM (default user, sudo available)
#   all       — all backends (default)

set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")" && pwd)"
PASS=0
FAIL=0

# Resolve GITHUB_TOKEN from gh CLI if not already set (5000 req/hr vs 60)
if [ -z "${GITHUB_TOKEN:-}" ] && command -v gh >/dev/null 2>&1; then
    GITHUB_TOKEN="$(gh auth token 2>/dev/null || true)"
fi
if [ -z "${GITHUB_TOKEN:-}" ]; then
    echo "WARNING: No GITHUB_TOKEN — GitHub downloads will hit 60 req/hr rate limit"
fi

# Resolve TS_AUTHKEY from 1Password if not already set
if [ -z "${TS_AUTHKEY:-}" ] && command -v op >/dev/null 2>&1; then
    TS_AUTHKEY="$(op read "op://Employee/Tailscale - Dev Auth Key/credential" --account industryvault.1password.com 2>/dev/null || true)"
fi
if [ -z "${TS_AUTHKEY:-}" ]; then
    echo "ERROR: No TS_AUTHKEY — Tailscale auth will fail. Set TS_AUTHKEY or sign in to 1Password."
    exit 1
fi
export TS_AUTHKEY GITHUB_TOKEN
log_pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
log_fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# Verification script injected into remote environments
read -r -d '' VERIFY_SCRIPT << 'VERIFY' || true
export PATH=$HOME/.local/bin:$HOME/.atuin/bin:$PATH
eval "$(fnm env 2>/dev/null)" || true

for cmd in starship uv atuin zoxide direnv fnm bat fzf rg jq yq gh duckdb carapace node claude codex op tailscale; do
    if command -v $cmd >/dev/null 2>&1; then echo "OK $cmd"; else echo "MISSING $cmd"; fi
done

# Tailscale connected with SSH enabled
if tailscale status >/dev/null 2>&1; then echo "OK tailscale-connected"; else echo "MISSING tailscale-connected"; fi

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
    if command -v op >/dev/null 2>&1 && [[ -n "$(op account list 2>/dev/null || true)" ]]; then
        for srv in github-home github-work; do
            if echo "$mcp_list" | grep -q "$srv"; then echo "OK mcp:$srv"; else echo "MISSING mcp:$srv"; fi
        done
    fi
fi

# Skills directories
for skill in bootstrap-project data-pipelines sprites-dev exe-dev mviz find-skills; do
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
    container run --name "$name" -d --cpus 4 --memory 4G ubuntu:25.04 sleep infinity
    sleep 3

    echo ""
    echo "--- Setting up user ---"
    container exec "$name" bash -c "
        apt-get update -qq && apt-get install -y -qq git curl sudo >/dev/null
        useradd -m -s /bin/bash $target_user
        echo '$target_user ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/$target_user
        chmod 440 /etc/sudoers.d/$target_user
    "

    echo ""
    echo "--- Installing as $target_user ---"
    # Clone from GitHub then overlay local changes via tar+container exec
    container exec "$name" bash -c "
        sudo -u $target_user git clone https://github.com/kylelundstedt/dotfiles /home/$target_user/dotfiles 2>/dev/null || true
    "
    COPYFILE_DISABLE=1 tar -C "$DOTFILES_DIR" --exclude=.git -cf - . | container exec -i "$name" bash -c "
        tar --warning=no-unknown-keyword -C /home/$target_user/dotfiles -xf -
        chown -R $target_user:$target_user /home/$target_user/dotfiles
    "
    container exec -e "TS_AUTHKEY=${TS_AUTHKEY:-}" -e "GITHUB_TOKEN=${GITHUB_TOKEN:-}" "$name" bash -c "
        sudo -u $target_user env TS_AUTHKEY=\"\$TS_AUTHKEY\" GITHUB_TOKEN=\"\$GITHUB_TOKEN\" bash -c 'cd ~/dotfiles && bash install.sh 2>&1'
    " || {
        log_fail "container: install.sh"
        container stop "$name" 2>/dev/null; container rm "$name" 2>/dev/null || true
        return
    }
    log_pass "container: install.sh"

    echo ""
    echo "--- Verifying ---"
    parse_results "container" "$(container exec "$name" bash -c "sudo -u $target_user bash -c '$VERIFY_SCRIPT'" 2>&1)"

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
    COPYFILE_DISABLE=1 tar -C "$DOTFILES_DIR" -cf - --exclude=.git . | sprite exec -s "$name" -- bash -c "
        sudo mkdir -p /home/$target_user/dotfiles
        sudo tar --warning=no-unknown-keyword -C /home/$target_user/dotfiles -xf -
        sudo chown -R $target_user:$target_user /home/$target_user/dotfiles
        cd /home/$target_user/dotfiles && sudo git init -q
    "
    sprite exec -s "$name" -env "TS_AUTHKEY=${TS_AUTHKEY:-},GITHUB_TOKEN=${GITHUB_TOKEN:-}" -- bash -c "
        sudo -u $target_user env TS_AUTHKEY=\"\$TS_AUTHKEY\" GITHUB_TOKEN=\"\$GITHUB_TOKEN\" bash -c 'cd ~/dotfiles && bash install.sh 2>&1'
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

# --- exe.dev VM (default user, sudo available) ---
# exe.dev lobby uses HTTPS API (reliable) for VM lifecycle.
# VM access uses SSH directly to <vm>.exe.xyz.
test_exe() {
    local name="tst-install-exe"
    local target_user="klundstedt"

    # Mint a bearer token from the 1Password-managed exe.dev SSH key
    local perms='{"cmds":["ls","new","rm","whoami"]}'
    local b64url_payload b64url_sig exe_token
    b64url_payload=$(printf '%s' "$perms" | base64 | tr -d '\n=' | tr '+/' '-_')
    b64url_sig=$(printf '%s' "$perms" | ssh-keygen -Y sign -f ~/.ssh/exe_dev.pub -n v0@exe.dev 2>/dev/null | sed '1d;$d' | tr -d '\n' | tr '+/' '-_' | tr -d '=')
    exe_token="exe0.$b64url_payload.$b64url_sig"

    # Helper: call exe.dev lobby via HTTPS API
    exe_api() { curl -s -X POST https://exe.dev/exec -H "Authorization: Bearer $exe_token" -d "$1"; }

    if ! exe_api "whoami" | grep -q '"email"'; then
        echo "exe.dev API not reachable — skipping exe test."
        return 0
    fi

    # SSH options for VM access (multiplexed)
    local ssh_mux_dir="/tmp/test-install-ssh-$$"
    mkdir -p "$ssh_mux_dir"
    local ssh_vm="ssh -o StrictHostKeyChecking=accept-new -o ControlMaster=auto -o ControlPath=$ssh_mux_dir/%r@%h-%p -o ControlPersist=300 -o ConnectTimeout=30"

    echo "=== exe.dev test (non-root, sudo available) ==="
    local vm_json vm_host
    vm_json=$(exe_api "new --name $name --image ubuntu:24.04" || true)
    vm_host=$(echo "$vm_json" | grep -oE '"ssh_dest":"[^"]+"' | head -1 | sed 's/"ssh_dest":"//;s/"//')
    if [[ -z "$vm_host" ]]; then
        log_fail "exe: create VM"
        return
    fi
    echo "  Created VM: $vm_host"

    # Wait for SSH to become available
    local attempt
    for attempt in 1 2 3 4 5; do
        $ssh_vm -o ConnectTimeout=5 "$vm_host" true 2>/dev/null && break
        sleep 3
    done

    echo ""
    echo "--- Setting up user ---"
    # exe.dev default user is root (no sudo preinstalled)
    $ssh_vm "$vm_host" "
        apt-get update -qq && apt-get install -y -qq git curl sudo >/dev/null
        useradd -m -s /bin/bash $target_user
        echo '$target_user ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/$target_user
        chmod 440 /etc/sudoers.d/$target_user
    "

    echo ""
    echo "--- Installing as $target_user ---"
    COPYFILE_DISABLE=1 tar -C "$DOTFILES_DIR" --exclude=.git -cf - . | $ssh_vm "$vm_host" "
        mkdir -p /home/$target_user/dotfiles
        tar --warning=no-unknown-keyword -C /home/$target_user/dotfiles -xf -
        chown -R $target_user:$target_user /home/$target_user/dotfiles
        cd /home/$target_user/dotfiles && git init -q
    "
    $ssh_vm "$vm_host" "
        sudo -u $target_user env TS_AUTHKEY='${TS_AUTHKEY:-}' GITHUB_TOKEN='${GITHUB_TOKEN:-}' bash -c 'cd ~/dotfiles && bash install.sh 2>&1'
    " || {
        log_fail "exe: install.sh"
        exe_api "rm $name" >/dev/null || true
        rm -rf "$ssh_mux_dir"
        return
    }
    log_pass "exe: install.sh"

    echo ""
    echo "--- Verifying ---"
    parse_results "exe" "$($ssh_vm "$vm_host" "sudo -u $target_user bash -c '$VERIFY_SCRIPT'" 2>&1)"

    echo ""
    echo "--- Tearing down exe.dev VM ---"
    exe_api "rm $name" >/dev/null || true
    rm -rf "$ssh_mux_dir"
}

# --- Dispatch ---
mode="${1:-all}"
case "$mode" in
    container) test_container ;;
    sprite)    test_sprite ;;
    exe)       test_exe ;;
    all)       test_container; test_sprite; test_exe ;;
    *)         echo "Usage: $0 [container|sprite|exe|all]"; exit 1 ;;
esac

TOTAL=$((PASS + FAIL))
echo ""
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
[[ $FAIL -gt 0 ]] && exit 1
exit 0

#!/bin/bash
# Test install.sh across the same backends zop uses.
# Usage: ./test-linux.sh [orb|container|sprite|all]
#   orb       — OrbStack VM (non-root, stow + idempotency)
#   container — Apple Container (root, no sudo)
#   sprite    — Fly.io Sprite (non-root, sudo available)
#   all       — all available backends (default)

set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")" && pwd)"
PASS=0
FAIL=0

log_pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
log_fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# Verification script injected into remote environments
read -r -d '' VERIFY_SCRIPT << 'VERIFY' || true
export PATH=$HOME/.local/bin:$PATH
eval "$(fnm env 2>/dev/null)" || true

for cmd in starship uv atuin zoxide direnv just fnm bat fzf rg jq yq gh duckdb carapace node; do
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

# --- OrbStack VM (non-root) ---
test_orb() {
    if ! command -v orbctl >/dev/null 2>&1; then
        echo "orbctl not found — skipping orb test."
        return 0
    fi

    local vm="test-dotfiles-orb-$$"
    echo "=== Orb test (non-root) ==="
    orbctl create ubuntu:24.04 "$vm"

    echo ""
    echo "--- First run ---"
    orbctl run -m "$vm" bash -c "
        ln -sf '$DOTFILES_DIR' ~/dotfiles
        cd ~/dotfiles && bash install.sh --no-prompt --skip-agents 2>&1
    " || {
        log_fail "orb: install.sh first run"
        orbctl delete --force "$vm" 2>/dev/null || true
        return
    }
    log_pass "orb: install.sh first run"

    echo ""
    echo "--- Verifying ---"
    parse_results "orb" "$(orbctl run -m "$vm" bash -c "$VERIFY_SCRIPT" 2>&1)"

    echo ""
    echo "--- Idempotency (second run) ---"
    orbctl run -m "$vm" bash -c "
        cd ~/dotfiles && bash install.sh --no-prompt --skip-agents 2>&1
    " || {
        log_fail "orb: idempotency"
        orbctl delete --force "$vm" 2>/dev/null || true
        return
    }
    log_pass "orb: idempotency"

    echo ""
    echo "--- Tearing down VM ---"
    orbctl delete --force "$vm" 2>/dev/null || true
}

# --- Apple Container (root, no sudo) ---
test_container() {
    if ! command -v container >/dev/null 2>&1; then
        echo "container CLI not found — skipping container test."
        return 0
    fi

    local name="test-dotfiles-ct-$$"
    echo "=== Container test (root) ==="
    container run --name "$name" ubuntu:25.04 sleep infinity &
    sleep 5

    echo ""
    echo "--- Installing as root ---"
    container exec "$name" bash -c "
        apt-get update -qq && apt-get install -y -qq git curl >/dev/null
        git clone https://github.com/kylelundstedt/dotfiles ~/dotfiles 2>/dev/null || true
        cd ~/dotfiles && bash install.sh --no-prompt --skip-agents 2>&1
    " || {
        log_fail "container: install.sh"
        container stop "$name" 2>/dev/null; container rm "$name" 2>/dev/null || true
        return
    }
    log_pass "container: install.sh"

    echo ""
    echo "--- Verifying ---"
    parse_results "container" "$(container exec "$name" bash -c "$VERIFY_SCRIPT" 2>&1)"

    echo ""
    echo "--- Tearing down container ---"
    container stop "$name" 2>/dev/null; container rm "$name" 2>/dev/null || true
}

# --- Sprite (non-root, sudo available) ---
test_sprite() {
    if ! command -v sprite >/dev/null 2>&1; then
        echo "sprite CLI not found — skipping sprite test."
        return 0
    fi

    local name="test-dotfiles-sp-$$"
    echo "=== Sprite test (non-root) ==="
    sprite create --skip-console "$name"

    echo ""
    echo "--- Installing ---"
    sprite exec -s "$name" -- bash -c "
        sudo apt-get update -qq && sudo apt-get install -y -qq git curl >/dev/null
        git clone https://github.com/kylelundstedt/dotfiles ~/dotfiles 2>/dev/null || true
        cd ~/dotfiles && bash install.sh --no-prompt --skip-agents 2>&1
    " || {
        log_fail "sprite: install.sh"
        sprite destroy -s "$name" --force 2>/dev/null || true
        return
    }
    log_pass "sprite: install.sh"

    echo ""
    echo "--- Verifying ---"
    parse_results "sprite" "$(sprite exec -s "$name" -- bash -c "$VERIFY_SCRIPT" 2>&1)"

    echo ""
    echo "--- Tearing down sprite ---"
    sprite destroy -s "$name" --force 2>/dev/null || true
}

# --- Dispatch ---
mode="${1:-all}"
case "$mode" in
    orb)       test_orb ;;
    container) test_container ;;
    sprite)    test_sprite ;;
    all)       test_orb; test_container; test_sprite ;;
    *)         echo "Usage: $0 [orb|container|sprite|all]"; exit 1 ;;
esac

TOTAL=$((PASS + FAIL))
echo ""
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
[[ $FAIL -gt 0 ]] && exit 1
exit 0

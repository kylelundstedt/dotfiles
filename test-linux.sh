#!/bin/bash
# Cross-context test suite for install.sh
# Tests install.sh in fresh instances across three execution contexts:
#   1. OrbStack VM (local context)
#   2. Apple Container (container context)
#   3. Sprite microVM (sprite context)
#
# Each test creates a fresh instance, runs the LOCAL install.sh (not GitHub master),
# validates output, and tears down. Tests whose CLI is not available are skipped.
#
# Usage: ./test-linux.sh

set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")" && pwd)"
VM_NAME="test-dotfiles-$$"

PASS=0
FAIL=0
SKIP=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log_pass() {
    echo "  PASS: $1"
    PASS=$((PASS + 1))
}

log_fail() {
    echo "  FAIL: $1"
    FAIL=$((FAIL + 1))
}

log_skip() {
    echo "  SKIP: $1"
    SKIP=$((SKIP + 1))
}

# assert_output LABEL PATTERN OUTPUT — pass if pattern found in output
assert_output() {
    local label="$1" pattern="$2" output="$3"
    if echo "$output" | grep -q "$pattern"; then
        log_pass "$label"
    else
        log_fail "$label — expected pattern: $pattern"
    fi
}

# assert_no_output LABEL PATTERN OUTPUT — pass if pattern NOT found in output
assert_no_output() {
    local label="$1" pattern="$2" output="$3"
    if echo "$output" | grep -q "$pattern"; then
        log_fail "$label — unexpected pattern found: $pattern"
    else
        log_pass "$label"
    fi
}

# ---------------------------------------------------------------------------
# Test: OrbStack VM (context=local)
# ---------------------------------------------------------------------------

test_orbstack() {
    echo ""
    echo "=== Test: OrbStack VM ==="

    if ! command -v orbctl >/dev/null 2>&1; then
        log_skip "orbctl not found"
        return
    fi

    local vm="$VM_NAME"
    local output=""
    local rc=0

    echo "  Creating OrbStack VM '$vm'..."
    orbctl create ubuntu:24.04 "$vm"

    # OrbStack shares the macOS filesystem — $DOTFILES_DIR is accessible inside the VM.
    # DOTFILES_BOOTSTRAP=1 skips the bootstrap clone/re-exec so we test the local copy.
    output=$(orbctl run -m "$vm" bash -c "
        export DEBIAN_FRONTEND=noninteractive
        sudo apt-get update -qq >/dev/null 2>&1
        sudo apt-get install -y -qq git curl sudo >/dev/null 2>&1
        DOTFILES_BOOTSTRAP=1 bash '$DOTFILES_DIR/install.sh' --only shell --no-prompt 2>&1
    ") || rc=$?

    if [[ $rc -eq 0 ]]; then
        log_pass "exit code 0"
    else
        log_fail "exit code $rc (expected 0)"
        echo "  --- output tail ---"
        echo "$output" | tail -20
        echo "  ---"
    fi

    assert_output "context is local" "Context: local" "$output"
    assert_output "layers = shell" "Layers: shell" "$output"
    assert_output "shell layer ran" "=== Shell layer ===" "$output"
    assert_no_output "no agent layer" "=== Agent layer ===" "$output"
    assert_no_output "no apps layer" "=== Apps layer ===" "$output"

    # Check installed commands
    local check_output=""
    check_output=$(orbctl run -m "$vm" bash -c "
        command -v stow && command -v starship && command -v zsh
    " 2>&1) || true

    if echo "$check_output" | grep -q "stow"; then
        log_pass "stow installed"
    else
        log_fail "stow not found"
    fi

    if echo "$check_output" | grep -q "starship"; then
        log_pass "starship installed"
    else
        log_fail "starship not found"
    fi

    if echo "$check_output" | grep -q "zsh"; then
        log_pass "zsh installed"
    else
        log_fail "zsh not found"
    fi

    echo "  Tearing down OrbStack VM '$vm'..."
    orbctl delete --force "$vm" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Test: Apple Container (context=container)
# ---------------------------------------------------------------------------

test_container() {
    echo ""
    echo "=== Test: Apple Container ==="

    if ! command -v container >/dev/null 2>&1; then
        log_skip "container CLI not found"
        return
    fi

    local ctr="$VM_NAME"
    local output=""
    local rc=0

    echo "  Creating Apple Container '$ctr'..."
    container run --name "$ctr" -d ubuntu:latest sleep infinity

    # Install prerequisites
    container exec "$ctr" bash -c "
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq git curl sudo >/dev/null 2>&1
    "

    # Copy local dotfiles into the container via tar
    container exec "$ctr" mkdir -p /root/dotfiles
    tar -cf - -C "$DOTFILES_DIR" --exclude=.git . | container exec -i "$ctr" tar -xf - -C /root/dotfiles 2>/dev/null

    # Run with DOTFILES_BOOTSTRAP=1 to use the copied local install.sh directly
    output=$(container exec "$ctr" bash -c "
        DOTFILES_BOOTSTRAP=1 bash /root/dotfiles/install.sh --only shell --no-prompt 2>&1
    ") || rc=$?

    if [[ $rc -eq 0 ]]; then
        log_pass "exit code 0"
    else
        log_fail "exit code $rc (expected 0)"
        echo "  --- output tail ---"
        echo "$output" | tail -20
        echo "  ---"
    fi

    assert_output "context is container" "Context: container" "$output"
    assert_output "layers = shell" "Layers: shell" "$output"
    assert_output "shell layer ran" "=== Shell layer ===" "$output"
    assert_no_output "no agent layer" "=== Agent layer ===" "$output"
    assert_no_output "no apps layer" "=== Apps layer ===" "$output"

    echo "  Tearing down container '$ctr'..."
    container delete --force "$ctr" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Test: Sprite microVM (context=microvm-sprite)
# ---------------------------------------------------------------------------

test_sprite() {
    echo ""
    echo "=== Test: Sprite microVM ==="

    if ! command -v sprite >/dev/null 2>&1; then
        log_skip "sprite CLI not found"
        return
    fi

    # Check if authenticated
    if ! sprite list >/dev/null 2>&1; then
        log_skip "sprite CLI not authenticated"
        return
    fi

    local vm="$VM_NAME"
    local output=""
    local rc=0

    echo "  Creating sprite '$vm'..."
    sprite create -skip-console "$vm"

    # Create a tarball of local dotfiles and upload via -file flag
    local tarball="/tmp/dotfiles-test-$$.tar.gz"
    tar -czf "$tarball" -C "$DOTFILES_DIR" --exclude=.git .

    sprite exec -s "$vm" -file "$tarball:/tmp/dotfiles.tar.gz" \
        bash -c "mkdir -p ~/dotfiles && tar -xzf /tmp/dotfiles.tar.gz -C ~/dotfiles 2>/dev/null" 2>/dev/null
    rm -f "$tarball"

    # Run with DOTFILES_BOOTSTRAP=1 to use the uploaded local install.sh directly
    output=$(sprite exec -s "$vm" bash -c "
        DOTFILES_BOOTSTRAP=1 bash ~/dotfiles/install.sh --only shell --no-prompt 2>&1
    ") || rc=$?

    if [[ $rc -eq 0 ]]; then
        log_pass "exit code 0"
    else
        log_fail "exit code $rc (expected 0)"
        echo "  --- output tail ---"
        echo "$output" | tail -20
        echo "  ---"
    fi

    assert_output "context is microvm-sprite" "Context: microvm-sprite" "$output"
    assert_output "layers = shell" "Layers: shell" "$output"
    assert_output "shell layer ran" "=== Shell layer ===" "$output"
    assert_no_output "no agent layer" "=== Agent layer ===" "$output"
    assert_no_output "no apps layer" "=== Apps layer ===" "$output"

    echo "  Tearing down sprite '$vm'..."
    sprite destroy --force "$vm" 2>/dev/null || true
    rm -f "$tarball" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Run tests
# ---------------------------------------------------------------------------

echo "Cross-context test suite for install.sh"
echo "========================================="

test_orbstack
test_container
test_sprite

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

TOTAL=$((PASS + FAIL))
echo ""
echo "========================================="
echo "Results: $PASS/$TOTAL passed, $FAIL failed, $SKIP skipped"

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi

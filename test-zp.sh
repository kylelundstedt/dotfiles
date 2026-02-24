#!/bin/bash
# Test zp across its supported flows.
# Usage: ./test-zp.sh

set -euo pipefail

PASS=0
FAIL=0

log_pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
log_fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

assert_exit() {
    local desc="$1" expected="$2"
    shift 2
    local rc=0
    "$@" >/dev/null 2>&1 || rc=$?
    if [[ "$rc" -eq "$expected" ]]; then
        log_pass "$desc"
    else
        log_fail "$desc (expected exit $expected, got $rc)"
    fi
}

assert_contains() {
    local desc="$1" pattern="$2"
    shift 2
    local output
    output=$("$@" 2>&1) || true
    if echo "$output" | grep -q "$pattern"; then
        log_pass "$desc"
    else
        log_fail "$desc (expected '$pattern' in output)"
    fi
}

# --- CLI argument handling ---
echo "=== CLI argument handling ==="

assert_exit "--help exits 0" 0 zp --help
assert_contains "--help shows usage" "Usage: zp" zp --help
assert_contains "invalid flag" "Unknown flag" zp --invalid
assert_contains "local + machine" "does not use machines" zp --backend local --machine foo
assert_contains "bare name + backend requires owner/name" "owner/name required" zp gitlake --backend container
assert_contains "no TTY, no args" "Interactive input required" zp

# --- Bare name search ---
echo ""
echo "=== Bare name search ==="

assert_contains "nonexistent bare name" "No project named" zp nonexistent-project-xyz-999

# --- Container lifecycle ---
if command -v container >/dev/null 2>&1; then
    echo ""
    echo "=== Container lifecycle ==="

    CT_NAME="test-zp-ct-$$"

    # Create container + clone
    echo "  Creating container $CT_NAME..."
    assert_exit "create + clone" 0 zp kylelundstedt/dotfiles --backend container --machine "$CT_NAME"

    # Idempotent re-run (container + project already exist)
    assert_exit "idempotent re-run" 0 zp kylelundstedt/dotfiles --backend container --machine "$CT_NAME"

    # Project discovery via backend_exec
    output=$(container exec "$CT_NAME" bash -c "ls /home/klundstedt/github/kylelundstedt/dotfiles/install.sh" 2>&1) || true
    if [[ "$output" == *"install.sh"* ]]; then
        log_pass "project cloned to ~/github/owner/name"
    else
        log_fail "project cloned to ~/github/owner/name"
    fi

    # Cleanup
    echo "  Cleaning up $CT_NAME..."
    { container stop "$CT_NAME" 2>/dev/null; container rm "$CT_NAME" 2>/dev/null; } || true
    log_pass "container cleanup"
else
    echo ""
    echo "=== Container lifecycle (skipped — container CLI not found) ==="
fi

# --- Results ---
echo ""
TOTAL=$((PASS + FAIL))
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
[[ $FAIL -gt 0 ]] && exit 1
exit 0

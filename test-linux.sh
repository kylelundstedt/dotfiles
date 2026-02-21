#!/bin/bash
# Test install.sh on a fresh Ubuntu VM via OrbStack.
# Usage: ./test-linux.sh

set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")" && pwd)"
VM_NAME="test-dotfiles-$$"

PASS=0
FAIL=0

log_pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
log_fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

assert_cmd() {
    local label="$1" output="$2"
    if echo "$output" | grep -q "$label"; then
        log_pass "$label found"
    else
        log_fail "$label not found"
    fi
}

if ! command -v orbctl >/dev/null 2>&1; then
    echo "orbctl not found — install OrbStack first."
    exit 1
fi

echo "=== Creating OrbStack VM '$VM_NAME' ==="
orbctl create ubuntu:24.04 "$VM_NAME"

echo ""
echo "=== Running install.sh ==="
output=$(orbctl run -m "$VM_NAME" bash -c "
    ln -sf '$DOTFILES_DIR' ~/dotfiles
    cd ~/dotfiles && bash install.sh --no-prompt --skip-stow 2>&1
") || {
    echo "FAIL: install.sh exited with non-zero"
    echo "$output" | tail -30
    orbctl delete --force "$VM_NAME" 2>/dev/null || true
    exit 1
}
log_pass "install.sh exit code 0"

echo ""
echo "=== Verifying CLI tools ==="
check_output=$(orbctl run -m "$VM_NAME" bash -c "
    export PATH=\$HOME/.local/bin:\$PATH
    eval \"\$(fnm env)\"
    for cmd in starship uv atuin zoxide direnv just fnm bat fzf rg jq yq gh duckdb carapace node npx claude; do
        if command -v \$cmd >/dev/null 2>&1; then
            echo \"OK \$cmd\"
        else
            echo \"MISSING \$cmd\"
        fi
    done
" 2>&1)

while IFS= read -r line; do
    case "$line" in
        OK*)     log_pass "${line#OK }" ;;
        MISSING*) log_fail "${line#MISSING }" ;;
    esac
done <<< "$check_output"

echo ""
echo "=== Tearing down VM ==="
orbctl delete --force "$VM_NAME" 2>/dev/null || true

TOTAL=$((PASS + FAIL))
echo ""
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
[[ $FAIL -gt 0 ]] && exit 1
exit 0

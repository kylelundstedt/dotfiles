#!/bin/bash
# Test install.sh across VM backends.
# exe.dev is the primary platform; Apple Container and Sprite paths are
# back-burnered but kept for occasional validation.
# Usage: ./test-install.sh [container|sprite|exe|hook|overlay|provisioning|all]
#   container    — Apple Container (back-burnered, kept for validation)
#   sprite       — Fly.io Sprite (back-burnered, kept for validation)
#   exe          — exe.dev VM (primary platform)
#   hook         — exe.dev setup-script hook smoke check only
#   provisioning — manifests vs installers drift check (local, no VM)
#   all          — all backends + local checks (default)

set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")" && pwd)"
PASS=0
FAIL=0
mode="${1:-all}"

# Resolve GITHUB_TOKEN from gh CLI if not already set (5000 req/hr vs 60)
if [ -z "${GITHUB_TOKEN:-}" ] && command -v gh >/dev/null 2>&1; then
    GITHUB_TOKEN="$(gh auth token 2>/dev/null || true)"
fi
if [ -z "${GITHUB_TOKEN:-}" ]; then
    echo "WARNING: No GITHUB_TOKEN — GitHub downloads will hit 60 req/hr rate limit"
fi

# Resolve TS_AUTHKEY from 1Password if not already set. Only the VM-creating
# modes need it — hook/provisioning are local smoke checks.
case "$mode" in container|sprite|exe|overlay|all)
    # Mint a short-lived reusable tag:dev key via the Tailscale OAuth client
    # (U11 — replaced the static iv-internal-test auth key). Reusable because
    # one test run may join several VMs; 1h expiry, ephemeral nodes.
    if [ -z "${TS_AUTHKEY:-}" ] && command -v op >/dev/null 2>&1; then
        _ts_cid="$(op read "op://Employee/Tailscale OAuth Dev/Client ID" --account industryvault.1password.com 2>/dev/null || true)"
        _ts_csec="$(op read "op://Employee/Tailscale OAuth Dev/Client secret" --account industryvault.1password.com 2>/dev/null || true)"
        if [ -n "$_ts_cid" ] && [ -n "$_ts_csec" ]; then
            _ts_tok="$(curl -fsS -m 15 -u "$_ts_cid:$_ts_csec" -d "grant_type=client_credentials" \
                https://api.tailscale.com/api/v2/oauth/token 2>/dev/null | jq -r '.access_token // empty' || true)"
            [ -n "$_ts_tok" ] && TS_AUTHKEY="$(curl -fsS -m 15 -X POST -H "Authorization: Bearer $_ts_tok" \
                -H "Content-Type: application/json" \
                -d '{"capabilities":{"devices":{"create":{"reusable":true,"ephemeral":true,"preauthorized":true,"tags":["tag:dev"]}}},"expirySeconds":3600,"description":"test-install"}' \
                https://api.tailscale.com/api/v2/tailnet/-/keys 2>/dev/null | jq -r '.key // empty' || true)"
        fi
    fi
    if [ -z "${TS_AUTHKEY:-}" ]; then
        echo "ERROR: No TS_AUTHKEY and OAuth mint failed. Set TS_AUTHKEY or sign in to 1Password."
        exit 1
    fi
    export TS_AUTHKEY
    ;;
esac
export GITHUB_TOKEN
log_pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
log_fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# Verification script injected into remote environments
read -r -d '' VERIFY_SCRIPT << 'VERIFY' || true
export PATH=$HOME/.local/bin:$HOME/.atuin/bin:$PATH
eval "$(fnm env 2>/dev/null)" || true

# Deliberate smoke SUBSET of provisioning/tools.manifest, not the full list —
# a hand-picked cross-section (curl installers, GitHub-release binaries, uv/fnm
# managed, agents). Full-list coverage is `./test-install.sh provisioning`
# (diff-provisioning.sh); keep this line short so remote runs stay readable.
for cmd in starship uv atuin zoxide direnv fnm bat fzf rg jq yq gh duckdb carapace node claude codex op tailscale; do
    if command -v $cmd >/dev/null 2>&1; then echo "OK $cmd"; else echo "MISSING $cmd"; fi
done

# Tailscale connected with SSH enabled
if tailscale status >/dev/null 2>&1; then echo "OK tailscale-connected"; else echo "MISSING tailscale-connected"; fi

# SSH config is a real file (not a stow symlink)
if [ -f ~/.ssh/config ] && [ ! -L ~/.ssh/config ]; then echo "OK ssh-config-file"; else echo "MISSING ssh-config-file"; fi

# SSH multiplexing
if grep -q "Host github.com" ~/.ssh/config 2>/dev/null; then echo "OK ssh-mux"; else echo "MISSING ssh-mux"; fi

# exe_dev.pub copied
if [ -f ~/.ssh/exe_dev.pub ]; then echo "OK exe-dev-key"; else echo "MISSING exe-dev-key"; fi

# exe.dev known host
if grep -q 'exe.dev' ~/.ssh/known_hosts 2>/dev/null; then echo "OK exe-known-host"; else echo "MISSING exe-known-host"; fi

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
for skill in sprites-dev join-tailnet upgrade-vm mviz find-skills installing-tigris-storage tigris-bucket-management tigris-object-operations tigris-snapshots-forking; do
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

# --- Apple Container (back-burnered, kept for validation) ---
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
        apt-get update -qq && apt-get install -y -qq curl sudo >/dev/null
        useradd -m -s /bin/bash $target_user
        echo '$target_user ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/$target_user
        chmod 440 /etc/sudoers.d/$target_user
    "

    echo ""
    echo "--- Installing via pipe (bootstrap path) ---"
    # Pipe local install.sh into bash — simulates `curl | bash`.
    # BASH_SOURCE is empty when piped, so bootstrap triggers: installs git, clones repo, re-execs.
    cat "$DOTFILES_DIR/install.sh" | container exec -i -e "TS_AUTHKEY=${TS_AUTHKEY:-}" -e "GITHUB_TOKEN=${GITHUB_TOKEN:-}" "$name" bash -c "
        sudo -u $target_user env TS_AUTHKEY=\"\$TS_AUTHKEY\" GITHUB_TOKEN=\"\$GITHUB_TOKEN\" bash 2>&1
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

# --- Sprite (back-burnered, kept for validation) ---
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
        sudo apt-get update -qq && sudo apt-get install -y -qq curl >/dev/null
        sudo useradd -m -s /bin/bash $target_user
        echo '$target_user ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/$target_user >/dev/null
        sudo chmod 440 /etc/sudoers.d/$target_user
    "

    echo ""
    echo "--- Installing via pipe (bootstrap path) ---"
    # Pipe local install.sh — bootstrap clones repo from GitHub and re-execs
    cat "$DOTFILES_DIR/install.sh" | sprite exec -s "$name" -env "TS_AUTHKEY=${TS_AUTHKEY:-},GITHUB_TOKEN=${GITHUB_TOKEN:-}" -- bash -c "
        sudo -u $target_user env TS_AUTHKEY=\"\$TS_AUTHKEY\" GITHUB_TOKEN=\"\$GITHUB_TOKEN\" bash 2>&1
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

    # Wait for SSH — per the repo's own exe.dev discipline: ~20s after
    # create, then ONE attempt with ConnectTimeout=30, then ONE retry after
    # 30s. Rapid-fire attempts trip exe.dev's per-IP SYN drop (minutes-long
    # lockout); the old 5×3s loop here predated that lesson.
    sleep 20
    if ! $ssh_vm -o ConnectTimeout=30 "$vm_host" true 2>/dev/null; then
        sleep 30
        $ssh_vm -o ConnectTimeout=30 "$vm_host" true 2>/dev/null || true
    fi

    echo ""
    echo "--- Setting up user ---"
    # exe.dev default user is root (no sudo preinstalled)
    $ssh_vm "$vm_host" "
        apt-get update -qq && apt-get install -y -qq curl sudo >/dev/null
        useradd -m -s /bin/bash $target_user
        echo '$target_user ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/$target_user
        chmod 440 /etc/sudoers.d/$target_user
    "

    echo ""
    echo "--- Installing via pipe (bootstrap path) ---"
    # Pipe local install.sh — bootstrap clones repo from GitHub and re-execs
    cat "$DOTFILES_DIR/install.sh" | $ssh_vm "$vm_host" "
        sudo -u $target_user env TS_AUTHKEY='${TS_AUTHKEY:-}' GITHUB_TOKEN='${GITHUB_TOKEN:-}' bash 2>&1
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

# --- Smoke check (always run) ---
# iv-image VMs join the tailnet on demand (the `join-tailnet` skill), not via a
# setup-script hook. Verify no auto-bootstrap hook is registered, so a stray
# `defaults write` can't silently reintroduce auto-join on every new VM.
test_no_hook() {
    echo ""
    echo "=== Smoke: exe.dev has no auto-join setup-script hook ==="
    local registered
    registered=$(ssh -o ConnectTimeout=10 -o BatchMode=yes exe.dev "defaults read dev.exe new.setup-script" 2>/dev/null || echo "")
    if [[ -z "$registered" ]]; then
        log_pass "no new.setup-script hook registered (on-demand join only)"
    else
        log_fail "a setup-script hook is registered ('$registered') — VMs will auto-run it at boot. Clear it: ssh exe.dev \"defaults delete dev.exe new.setup-script\""
    fi
}

# --- Provisioning drift check (local, no VM) ---
# Manifests in provisioning/ declare the intended skill/MCP/tool sets;
# diff-provisioning.sh flags divergence from install.sh and the iv-image
# installers (when the iv-image clone is present).
test_provisioning() {
    echo ""
    echo "=== Provisioning manifests vs installers (local) ==="
    if "$DOTFILES_DIR/provisioning/diff-provisioning.sh" > /tmp/diff-provisioning.out 2>&1; then
        log_pass "manifests match installers (diff-provisioning.sh)"
    else
        log_fail "provisioning drift found — see /tmp/diff-provisioning.out"
    fi
    # healthchecks.io check configs vs checks.manifest (mini-only: needs the
    # API key in the Keychain; the script self-skips elsewhere).
    if "$DOTFILES_DIR/provisioning/check-monitoring.sh" > /tmp/check-monitoring.out 2>&1; then
        log_pass "healthchecks configs match checks.manifest (check-monitoring.sh)"
    else
        log_fail "monitoring drift found — see /tmp/check-monitoring.out"
    fi
}

# --- IV overlay (U7): dotfiles as a thin personal overlay on an IV VM ---
# Provisions iv-image (team baseline) on a fresh exeuntu VM, then runs the
# PUSHED dotfiles install.sh (the pipe self-bootstraps from GitHub master) and
# asserts the overlay behavior: team baseline intact, personal delta layered.
test_overlay() {
    echo ""
    echo "=== IV overlay test (iv-image baseline + dotfiles personal delta) ==="
    local vm="test-iv-overlay"
    if ! ssh -o ConnectTimeout=30 exe.dev "new --name=$vm --tag=iv --integration=github-kylelundstedt-iv-image" >/dev/null 2>&1; then
        log_fail "overlay: VM create failed"; return
    fi
    sleep 20   # VM boot + integration propagation (first clone may still 404 — retried below)
    echo "--- provisioning iv-image (team baseline) ---"
    if ssh -o ConnectTimeout=30 -o StrictHostKeyChecking=accept-new "$vm.exe.xyz" '
        for i in 1 2 3; do
            git clone -q https://github-kylelundstedt-iv-image.int.exe.xyz/kylelundstedt/iv-image.git ~/iv-image 2>/dev/null && break
            sleep 20
        done
        [ -d ~/iv-image ] && ~/iv-image/provision-iv.sh > /tmp/provision.log 2>&1 && [ -f ~/iv-provision.lock ]'; then
        log_pass "overlay: iv-image provisioned"
    else
        log_fail "overlay: iv-image provisioning failed"
        ssh -o ConnectTimeout=30 exe.dev "rm $vm" >/dev/null 2>&1 || true
        return
    fi
    echo "--- running dotfiles install.sh (overlay path) ---"
    if cat "$DOTFILES_DIR/install.sh" | ssh -o ConnectTimeout=30 "$vm.exe.xyz" \
        "env TS_AUTHKEY='${TS_AUTHKEY:-}' GITHUB_TOKEN='${GITHUB_TOKEN:-}' bash" > /tmp/overlay-install.log 2>&1; then
        log_pass "overlay: install.sh completed"
    else
        log_fail "overlay: install.sh failed — see /tmp/overlay-install.log"
    fi
    echo "--- verifying overlay invariants ---"
    parse_results "overlay" "$(ssh -o ConnectTimeout=30 "$vm.exe.xyz" 'bash -s' << 'OVERLAY_VERIFY'
export PATH=$HOME/.local/bin:$PATH
A=~/.agents/AGENTS.md
grep -q "IV Agent Instructions" "$A" && echo "OK team-agents-header" || echo "MISSING team-agents-header"
[ "$(grep -c ">>> personal overlay" "$A")" = 1 ] && echo "OK personal-overlay-block" || echo "MISSING personal-overlay-block"
grep -q "^## Memory" "$A" && echo "OK personal-section-memory" || echo "MISSING personal-section-memory"
grep -q "^## Cloud CLIs" "$A" && echo "OK team-section-cloud-clis" || echo "MISSING team-section-cloud-clis"
[ "$(grep "^## " "$A" | sort | uniq -d | wc -l)" = 0 ] && echo "OK no-duplicate-sections" || echo "MISSING no-duplicate-sections"
[ -f ~/.claude/settings.json ] && [ ! -L ~/.claude/settings.json ] && echo "OK team-settings-intact" || echo "MISSING team-settings-intact"
grep -q "refresh-env.sh" ~/.claude/settings.json && grep -q "exe.dev SSH guard" ~/.claude/settings.json && echo "OK settings-hook-spliced" || echo "MISSING settings-hook-spliced"
[ -L ~/.agents/refresh-env.sh ] && echo "OK agents-package-stowed" || echo "MISSING agents-package-stowed"
mcp_list=$(claude mcp list 2>/dev/null || true)
for srv in motherduck github-work github-home tigris readwise; do
    echo "$mcp_list" | grep -q "$srv" && echo "OK mcp:$srv" || echo "MISSING mcp:$srv"
done
duckdb --version 2>/dev/null | grep -q "1.5.3" && echo "OK team-tool-pinned-duckdb" || echo "MISSING team-tool-pinned-duckdb"
command -v starship >/dev/null && echo "OK personal-tool-starship" || echo "MISSING personal-tool-starship"
grep -q ">>> dotfiles ssh" ~/.ssh/config && echo "OK ssh-dotfiles-block" || echo "MISSING ssh-dotfiles-block"
grep -q ">>> iv-provision ssh" ~/.ssh/config && echo "OK ssh-iv-block-preserved" || echo "MISSING ssh-iv-block-preserved"
[ "$(grep -vE '^#|^$' ~/.ssh/config | head -1 | awk '{print $1}')" = "CanonicalizeHostname" ] && echo "OK ssh-canonicalize-first" || echo "MISSING ssh-canonicalize-first"
OVERLAY_VERIFY
)"
    echo "--- tearing down ---"
    ssh -o ConnectTimeout=30 exe.dev "rm $vm" >/dev/null 2>&1 && echo "  VM deleted"
}

# --- Dispatch ---
case "$mode" in
    container)    test_container ;;
    sprite)       test_sprite ;;
    exe)          test_no_hook; test_exe ;;
    overlay)      test_overlay ;;
    all)          test_provisioning; test_no_hook; test_container; test_sprite; test_exe; test_overlay ;;
    hook)         test_no_hook ;;
    provisioning) test_provisioning ;;
    *)            echo "Usage: $0 [container|sprite|exe|hook|overlay|provisioning|all]"; exit 1 ;;
esac

TOTAL=$((PASS + FAIL))
echo ""
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
[[ $FAIL -gt 0 ]] && exit 1
exit 0

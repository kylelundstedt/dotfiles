#!/usr/bin/env bash
# Sync all non-archived, non-fork repos from personal and work GitHub accounts.
# Clones missing repos (SSH), fetches existing ones (SSH).
# Runs serially to avoid overwhelming SSH/1Password agent.
set -euo pipefail

PERSONAL_DIR="$HOME/github/kylelundstedt"
WORK_DIR="$HOME/github/klundstedt"

sync_repos() {
    local owner="$1" target_dir="$2"
    mkdir -p "$target_dir"

    echo "==> Syncing $owner → $target_dir"

    gh repo list "$owner" \
        --limit 1000 \
        --no-archived \
        --source \
        --json name,sshUrl \
        --jq '.[] | "\(.name) \(.sshUrl)"' |
    while read -r name url; do
        local repo_dir="$target_dir/$name"
        if [ -d "$repo_dir/.git" ]; then
            echo "  fetch $name"
            git -C "$repo_dir" fetch --all --quiet 2>&1 || echo "  WARN: fetch failed for $name"
        else
            echo "  clone $name"
            git clone --quiet "$url" "$repo_dir" 2>&1 || echo "  WARN: clone failed for $name"
        fi
    done
}

sync_repos kylelundstedt "$PERSONAL_DIR"
sync_repos IndustryVault "$WORK_DIR"
sync_repos iv-cmg "$WORK_DIR"

echo "==> Done $(date)"

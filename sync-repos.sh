#!/usr/bin/env bash
# Sync all non-archived, non-fork repos from personal and work GitHub accounts.
# Clones missing repos (SSH), fetches existing ones (SSH).
# Runs serially to avoid overwhelming SSH/1Password agent.
#
# Scheduled by two LaunchAgents:
#   - midnight daily (StartCalendarInterval)
#   - every 12h as a catch-up for wake-from-sleep (StartInterval)
# Staleness check below prevents redundant runs.
set -euo pipefail

LAST_RUN_FILE="/tmp/sync-repos.lastrun"
LOCKFILE="/tmp/sync-repos.lock"
MIN_INTERVAL=$((20 * 3600))  # 20 hours
PERSONAL_DIR="$HOME/github/kylelundstedt"
WORK_DIR="$HOME/github/klundstedt"
SKIP_REPOS="dotfiles"  # managed separately at ~/dotfiles

# Skip if last successful run was recent
if [[ -f "$LAST_RUN_FILE" ]]; then
    last_run=$(cat "$LAST_RUN_FILE")
    now=$(date +%s)
    if (( now - last_run < MIN_INTERVAL )); then
        echo "Last sync was $(( (now - last_run) / 3600 ))h ago, skipping."
        exit 0
    fi
fi

# Prevent overlapping runs
if ! mkdir "$LOCKFILE" 2>/dev/null; then
    echo "Another sync-repos is already running (lockfile: $LOCKFILE). Exiting."
    exit 0
fi
trap 'rmdir "$LOCKFILE" 2>/dev/null' EXIT

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
        if [[ " $SKIP_REPOS " == *" $name "* ]]; then
            echo "  skip $name (managed separately)"
            continue
        fi
        sleep 1
        local repo_dir="$target_dir/$name"
        if [ -d "$repo_dir/.git" ]; then
            if git -C "$repo_dir" rev-parse HEAD >/dev/null 2>&1; then
                echo "  fetch $name"
                git -C "$repo_dir" fetch --all --quiet 2>&1 || echo "  WARN: fetch failed for $name"
            else
                echo "  WARN: $name has corrupt .git, removing and re-cloning"
                rm -rf "$repo_dir"
                git clone --quiet "$url" "$repo_dir" 2>&1 || echo "  WARN: re-clone failed for $name"
            fi
        else
            echo "  clone $name"
            if ! git clone --quiet "$url" "$repo_dir" 2>&1; then
                echo "  WARN: clone failed for $name, cleaning up"
                rm -rf "$repo_dir"
            fi
        fi
    done
}

sync_repos kylelundstedt "$PERSONAL_DIR"
sync_repos IndustryVault "$WORK_DIR"
sync_repos iv-cmg "$WORK_DIR"

date +%s > "$LAST_RUN_FILE"
echo "==> Done $(date)"

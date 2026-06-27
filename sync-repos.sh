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
GITHUB_DIR="$HOME/github"
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

    # Capture the listing first so an empty result is visible rather than a
    # silent no-op. A fine-grained PAT that lacks access to an org returns 0
    # repos here even though SSH clone access may work — surface that loudly.
    local listing
    listing=$(gh repo list "$owner" \
        --limit 1000 \
        --no-archived \
        --source \
        --json name,sshUrl \
        --jq '.[] | "\(.name) \(.sshUrl)"' 2>/dev/null)
    if [[ -z "$listing" ]]; then
        echo "  WARN: 0 repos visible for '$owner'. The active GitHub token may not"
        echo "        have access to this org (check: gh repo list $owner). Skipping."
        return 0
    fi

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
                # Fast-forward default branch so local HEAD stays current
                local default_branch
                default_branch=$(git -C "$repo_dir" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')
                if [[ -n "$default_branch" ]]; then
                    local current_branch
                    current_branch=$(git -C "$repo_dir" symbolic-ref --short HEAD 2>/dev/null || true)
                    if [[ "$current_branch" == "$default_branch" ]]; then
                        git -C "$repo_dir" merge --ff-only "origin/$default_branch" --quiet 2>/dev/null || true
                    fi
                fi
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
    done <<< "$listing"
}

sync_repos kylelundstedt "$GITHUB_DIR/kylelundstedt"
sync_repos IndustryVault "$GITHUB_DIR/IndustryVault"
sync_repos iv-cmg "$GITHUB_DIR/iv-cmg"
sync_repos USAA "$GITHUB_DIR/USAA"

date +%s > "$LAST_RUN_FILE"
echo "==> Done $(date)"

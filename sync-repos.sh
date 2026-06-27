#!/usr/bin/env bash
# Sync all non-archived, non-fork repos from personal and work GitHub accounts.
# Fine-grained PATs are per-resource-owner, so each owner needs its own token:
#   - kylelundstedt, USAA  -> gh's Home token (gh auth token)
#   - IndustryVault, iv-cmg -> per-org PATs in the macOS login Keychain
#     (service names sync-repos:IndustryVault / sync-repos:iv-cmg; add with:
#       security add-generic-password -a "$USER" -s "sync-repos:<owner>" \
#         -T /usr/bin/security -U -w "$(op read 'op://Employee/GitHub PAT IV/token' ...)")
# Clone/fetch tries SSH first, then falls back to HTTPS with the per-org token
# (covers orgs where the SSH key lacks SSO authorization, e.g. USAA).
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

# GIT_ASKPASS helper: prints the token in $SYNC_REPOS_TOKEN so HTTPS clone/fetch
# can authenticate without ever putting the token in a remote URL or argv.
ASKPASS="$(mktemp -t sync-repos-askpass)"
printf '#!/bin/sh\nprintf "%%s" "$SYNC_REPOS_TOKEN"\n' > "$ASKPASS"
chmod +x "$ASKPASS"
trap 'rmdir "$LOCKFILE" 2>/dev/null; rm -f "$ASKPASS"' EXIT

# Resolve the GitHub token for an owner.
token_for() {
    case "$1" in
        IndustryVault) security find-generic-password -s "sync-repos:IndustryVault" -w 2>/dev/null ;;
        iv-cmg)        security find-generic-password -s "sync-repos:iv-cmg" -w 2>/dev/null ;;
        *)             gh auth token 2>/dev/null ;;  # kylelundstedt, USAA -> Home
    esac
}

sync_repos() {
    local owner="$1" target_dir="$2"
    mkdir -p "$target_dir"

    echo "==> Syncing $owner → $target_dir"

    local tok
    tok="$(token_for "$owner")"
    if [[ -z "$tok" ]]; then
        echo "  WARN: no token for '$owner' (Keychain item sync-repos:$owner missing?). Skipping."
        return 0
    fi

    # Capture the listing first so an empty result is visible rather than a
    # silent no-op (a token without access to the org returns 0 repos).
    local listing
    listing=$(GH_TOKEN="$tok" gh repo list "$owner" \
        --limit 1000 \
        --no-archived \
        --source \
        --json name \
        --jq '.[].name' 2>/dev/null)
    if [[ -z "$listing" ]]; then
        echo "  WARN: 0 repos visible for '$owner' with its token. Skipping."
        return 0
    fi

    while read -r name; do
        [[ -z "$name" ]] && continue
        if [[ " $SKIP_REPOS " == *" $name "* ]]; then
            echo "  skip $name (managed separately)"
            continue
        fi
        sleep 1
        local repo_dir="$target_dir/$name"
        local ssh_url="git@github.com:$owner/$name.git"
        local https_url="https://x-access-token@github.com/$owner/$name.git"
        if [ -d "$repo_dir/.git" ]; then
            if git -C "$repo_dir" rev-parse HEAD >/dev/null 2>&1; then
                echo "  fetch $name"
                SYNC_REPOS_TOKEN="$tok" GIT_ASKPASS="$ASKPASS" GIT_TERMINAL_PROMPT=0 \
                    git -C "$repo_dir" fetch --all --quiet 2>&1 || echo "  WARN: fetch failed for $name"
                # Fast-forward default branch so local HEAD stays current
                local default_branch current_branch
                default_branch=$(git -C "$repo_dir" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')
                if [[ -n "$default_branch" ]]; then
                    current_branch=$(git -C "$repo_dir" symbolic-ref --short HEAD 2>/dev/null || true)
                    if [[ "$current_branch" == "$default_branch" ]]; then
                        git -C "$repo_dir" merge --ff-only "origin/$default_branch" --quiet 2>/dev/null || true
                    fi
                fi
            else
                echo "  WARN: $name has corrupt .git, removing and re-cloning"
                rm -rf "$repo_dir"
                clone_repo "$ssh_url" "$https_url" "$repo_dir" "$tok" || echo "  WARN: re-clone failed for $name"
            fi
        else
            echo "  clone $name"
            clone_repo "$ssh_url" "$https_url" "$repo_dir" "$tok" || echo "  WARN: clone failed for $name"
        fi
    done <<< "$listing"
}

# Clone via SSH; if that fails (e.g. SSH key not SSO-authorized for the org),
# retry over HTTPS using the per-org token via GIT_ASKPASS.
clone_repo() {
    local ssh_url="$1" https_url="$2" dir="$3" tok="$4"
    if git clone --quiet "$ssh_url" "$dir" 2>/dev/null; then
        return 0
    fi
    rm -rf "$dir"
    SYNC_REPOS_TOKEN="$tok" GIT_ASKPASS="$ASKPASS" GIT_TERMINAL_PROMPT=0 \
        git clone --quiet "$https_url" "$dir" 2>&1
}

sync_repos kylelundstedt "$GITHUB_DIR/kylelundstedt"
sync_repos IndustryVault "$GITHUB_DIR/IndustryVault"
sync_repos iv-cmg "$GITHUB_DIR/iv-cmg"
sync_repos USAA "$GITHUB_DIR/USAA"

date +%s > "$LAST_RUN_FILE"
echo "==> Done $(date)"

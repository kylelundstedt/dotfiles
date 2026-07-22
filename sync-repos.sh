#!/usr/bin/env bash
# Sync all source (non-fork) repos, INCLUDING archived, from personal and work
# GitHub accounts. Archived repos are kept because this is a backup/DR mirror:
# they're frozen and are exactly the ones you might later delete from GitHub.
# Fine-grained PATs are per-resource-owner, so each owner needs its own token:
#   - kylelundstedt, USAA  -> gh's Home token (gh auth token)
#   - IndustryVault, iv-cmg -> per-org PATs in the macOS login Keychain
#     (service names sync-repos:IndustryVault / sync-repos:iv-cmg; add with:
#       security add-generic-password -a "$USER" -s "sync-repos:<owner>" \
#         -T /usr/bin/security -U -w "$(op read 'op://Employee/GitHub PAT IV/token' ...)")
# Clone/fetch tries SSH first, then falls back to HTTPS with the per-org token
# (covers orgs where the SSH key lacks SSO authorization, e.g. USAA).
#
# Scheduled by ONE LaunchAgent carrying both triggers: midnight daily
# (StartCalendarInterval) + every 12h as a wake-from-sleep catch-up
# (StartInterval). Staleness check below prevents redundant runs.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/backup/_lib.sh"

LAST_RUN_FILE="/tmp/sync-repos.lastrun"
LOCKFILE="/tmp/sync-repos.lock"
MIN_INTERVAL=$((20 * 3600))  # 20 hours
GITHUB_DIR="$HOME/github"
SKIP_REPOS="dotfiles"  # managed separately at ~/dotfiles
FAILED=0; FAILED_REPOS=()  # hard failures — used to fail the healthcheck honestly

# Monitoring + skip/lock semantics come from backup/_lib.sh: the staleness skip
# pings success by construction (lastrun is only written by a clean run, so
# "fresh" IS success). Two triggers plus ad-hoc manual runs mean skips are
# normal; a silent skip would false-alarm the check red (see the lib header).
job_hc_init "sync-repos:healthcheck-url"

if job_stale_skip "$LAST_RUN_FILE" "$MIN_INTERVAL"; then
    echo "Last sync was ${JOB_STALE_AGE_H}h ago, skipping."
    exit 0
fi

# Prevent overlapping runs
if ! job_lock "$LOCKFILE"; then
    echo "Another sync-repos is already running (lockfile: $LOCKFILE). Exiting."
    exit 0
fi

# GIT_ASKPASS helper: prints the token in $SYNC_REPOS_TOKEN so HTTPS clone/fetch
# can authenticate without ever putting the token in a remote URL or argv.
ASKPASS="$(mktemp -t sync-repos-askpass)"
printf '#!/bin/sh\nprintf "%%s" "$SYNC_REPOS_TOKEN"\n' > "$ASKPASS"
chmod +x "$ASKPASS"
# /start at begin, success on clean exit, /fail otherwise.
# Success ONLY on a clean exit with zero failed repos — a partial failure (or a
# mid-run set -e abort) pings /fail with a summary so the check goes red honestly.
finish() {
    local rc=$?; set +e
    rmdir "$LOCKFILE" 2>/dev/null; rm -f "$ASKPASS"
    if [ "$rc" -eq 0 ] && [ "$FAILED" -eq 0 ]; then
        job_hc
    else
        job_hc /fail --data-raw "sync-repos $(scutil --get LocalHostName 2>/dev/null) $(date '+%F %T') rc=$rc failed=$FAILED: ${FAILED_REPOS[*]:-aborted-early}"
    fi
}
trap finish EXIT
job_hc /start

# Resolve the GitHub token for an owner.
token_for() {
    case "$1" in
        IndustryVault) job_kc "sync-repos:IndustryVault" ;;
        iv-cmg)        job_kc "sync-repos:iv-cmg" ;;
        *)             gh auth token 2>/dev/null ;;  # kylelundstedt, USAA -> Home
    esac
}

# Run git over HTTPS with a per-owner token. The scheduled job must not rely on
# an interactive credential helper: it supplies the token through GIT_ASKPASS.
git_https() { # tok owner git-args...
    local tok="$1" owner="$2"; shift 2
    SYNC_REPOS_TOKEN="$tok" GIT_ASKPASS="$ASKPASS" GIT_TERMINAL_PROMPT=0 \
        git -c "credential.helper=" "$@"
}

sync_repos() {
    local owner="$1" target_dir="$2"
    mkdir -p "$target_dir"

    echo "==> Syncing $owner → $target_dir"

    # Owner-level auth/listing problems must FAIL the run loudly: a missing
    # Keychain token or an expired PAT makes the listing fail/empty, and a
    # silent skip here kept updating lastrun + pinging the healthcheck green
    # while an entire org's mirror went stale (found in the 2026-07-13
    # cross-review). All four owners always have source repos, so an empty
    # listing means broken auth/scope, not an empty account.
    local tok
    tok="$(token_for "$owner")"
    if [[ -z "$tok" ]]; then
        echo "  FAIL: no token for '$owner' (Keychain item sync-repos:$owner missing, or gh auth broken) — owner NOT mirrored"
        FAILED=$((FAILED+1)); FAILED_REPOS+=("$owner/(no-token)")
        return 0
    fi

    local listing gh_err
    gh_err=$(mktemp -t sync-repos-gh-err)
    if ! listing=$(GH_TOKEN="$tok" gh repo list "$owner" \
        --limit 1000 \
        --source \
        --json name \
        --jq '.[].name' 2>"$gh_err"); then
        echo "  FAIL: repo listing for '$owner' failed: $(head -1 "$gh_err") — owner NOT mirrored"
        rm -f "$gh_err"
        FAILED=$((FAILED+1)); FAILED_REPOS+=("$owner/(listing-failed)")
        return 0
    fi
    rm -f "$gh_err"
    if [[ -z "$listing" ]]; then
        echo "  FAIL: 0 repos visible for '$owner' (expired PAT / missing scope?) — owner NOT mirrored"
        FAILED=$((FAILED+1)); FAILED_REPOS+=("$owner/(empty-listing)")
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
        if [ -d "$repo_dir/.git" ]; then
            if git -C "$repo_dir" rev-parse HEAD >/dev/null 2>&1; then
                echo "  fetch $name"
                # Normalize historical SSH/case-variant origins to canonical HTTPS.
                # This is idempotent and keeps unattended sync independent of SSH.
                git -C "$repo_dir" remote set-url origin "https://github.com/$owner/$name.git" 2>/dev/null || true
                if git_https "$tok" "$owner" -C "$repo_dir" fetch --all --quiet; then
                    # Fast-forward default branch so local HEAD stays current.
                    local default_branch current_branch
                    default_branch=$(git -C "$repo_dir" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||') || default_branch=""
                    if [[ -n "$default_branch" ]]; then
                        current_branch=$(git -C "$repo_dir" symbolic-ref --short HEAD 2>/dev/null) || current_branch=""
                        if [[ "$current_branch" == "$default_branch" ]]; then
                            git -C "$repo_dir" merge --ff-only "origin/$default_branch" --quiet 2>/dev/null || true
                        fi
                    fi
                else
                    echo "  WARN: fetch failed for $name"; FAILED=$((FAILED+1)); FAILED_REPOS+=("$owner/$name")
                fi
            else
                echo "  WARN: $name has corrupt .git, removing and re-cloning"
                clone_repo "$owner" "$name" "$repo_dir" "$tok"
            fi
        else
            echo "  clone $name"
            clone_repo "$owner" "$name" "$repo_dir" "$tok"
        fi
    done <<< "$listing"
}

# Clone directly over HTTPS. SSH is never attempted by the scheduled job.
clone_repo() {
    local owner="$1" name="$2" dir="$3" tok="$4"
    rm -rf "$dir"
    if ! git_https "$tok" "$owner" clone --quiet "https://github.com/$owner/$name.git" "$dir"; then
        echo "  WARN: clone failed for $owner/$name"; rm -rf "$dir"
        FAILED=$((FAILED+1)); FAILED_REPOS+=("$owner/$name")
    fi
}

sync_repos kylelundstedt "$GITHUB_DIR/kylelundstedt"
sync_repos IndustryVault "$GITHUB_DIR/IndustryVault"
sync_repos iv-cmg "$GITHUB_DIR/iv-cmg"
sync_repos USAA "$GITHUB_DIR/USAA"

# Mark lastrun ONLY on a clean run: a failed run must not arm the staleness
# skip, or the 12h catch-up run skips + pings success over a red check
# (the 2026-07 up/down flapping). Leaving lastrun stale makes every scheduled
# run retry in full until one succeeds.
if [[ "$FAILED" -gt 0 ]]; then
    echo "==> Done $(date) — $FAILED repo(s) FAILED: ${FAILED_REPOS[*]}"
else
    job_mark_done "$LAST_RUN_FILE"
    echo "==> Done $(date) — all repos synced"
fi

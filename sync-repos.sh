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
FAILED=0; FAILED_REPOS=()  # hard failures — used to fail the healthcheck honestly

# Dead-man's-switch heartbeat (healthchecks.io). Ping URL in the login Keychain
# (sync-repos:healthcheck-url) — mini-only, no-op if absent. Defined up here so the
# staleness skip below can ALSO ping success: a skip means "a sync ran recently
# enough" (fresh data), which is success for the monitor — not a missed run. Two
# schedules (midnight + 12h wakeup) plus ad-hoc manual runs mean skips are normal;
# without this ping the grace window expires and the check false-alarms red.
hc() { local u; u=$(security find-generic-password -s "sync-repos:healthcheck-url" -w 2>/dev/null); [ -n "$u" ] && curl -fsS -m 10 --retry 3 "${u}${1:-}" "${@:2}" >/dev/null 2>&1 || true; }

# Skip if last successful run was recent — still ping success (data is fresh).
if [[ -f "$LAST_RUN_FILE" ]]; then
    last_run=$(cat "$LAST_RUN_FILE")
    now=$(date +%s)
    if (( now - last_run < MIN_INTERVAL )); then
        echo "Last sync was $(( (now - last_run) / 3600 ))h ago, skipping."
        hc; exit 0
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
# (hc heartbeat helper is defined near the top so the staleness skip can use it.)
# /start at begin, success on clean exit, /fail otherwise.
# Success ONLY on a clean exit with zero failed repos — a partial failure (or a
# mid-run set -e abort) pings /fail with a summary so the check goes red honestly.
finish() {
    local rc=$?; set +e
    rmdir "$LOCKFILE" 2>/dev/null; rm -f "$ASKPASS"
    if [ "$rc" -eq 0 ] && [ "$FAILED" -eq 0 ]; then
        hc
    else
        hc /fail --data-raw "sync-repos $(scutil --get LocalHostName 2>/dev/null) $(date '+%F %T') rc=$rc failed=$FAILED: ${FAILED_REPOS[*]:-aborted-early}"
    fi
}
trap finish EXIT
hc /start

# Resolve the GitHub token for an owner.
token_for() {
    case "$1" in
        IndustryVault) security find-generic-password -s "sync-repos:IndustryVault" -w 2>/dev/null ;;
        iv-cmg)        security find-generic-password -s "sync-repos:iv-cmg" -w 2>/dev/null ;;
        *)             gh auth token 2>/dev/null ;;  # kylelundstedt, USAA -> Home
    esac
}

# Run git over HTTPS with a per-owner token — NO SSH. The scheduled job runs in a
# launchd context where the 1Password SSH agent is unavailable/locked, so any
# git@github.com SSH op fails ("communication with agent failed"). insteadOf
# rewrites SSH (and bare-HTTPS) remotes to a tokened HTTPS URL at transport time,
# so existing repos (SSH origin) and USAA (SSH key not SSO-authorized) all work.
# The username is embedded (x-access-token@) so git only prompts for the password,
# which GIT_ASKPASS supplies from $SYNC_REPOS_TOKEN.
git_https() { # tok git-args...
    local tok="$1"; shift
    # credential.helper= (empty) resets the helper list so git does NOT consult
    # the osxkeychain helper (which pops a GUI keychain-unlock prompt that would
    # hang the unattended job) — the token comes straight from GIT_ASKPASS.
    SYNC_REPOS_TOKEN="$tok" GIT_ASKPASS="$ASKPASS" GIT_TERMINAL_PROMPT=0 \
        git -c "credential.helper=" \
            -c "url.https://x-access-token@github.com/.insteadOf=git@github.com:" \
            -c "url.https://x-access-token@github.com/.insteadOf=https://github.com/" \
            "$@"
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
        --source \
        --json name \
        --jq '.[].name' 2>/dev/null) || listing=""
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
        if [ -d "$repo_dir/.git" ]; then
            if git -C "$repo_dir" rev-parse HEAD >/dev/null 2>&1; then
                echo "  fetch $name"
                if git_https "$tok" -C "$repo_dir" fetch --all --quiet; then
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

# Clone over HTTPS+token (git_https rewrites the SSH URL). SSH is never attempted:
# it can't work in the unattended launchd context (no 1Password agent).
clone_repo() {
    local owner="$1" name="$2" dir="$3" tok="$4"
    rm -rf "$dir"
    if ! git_https "$tok" clone --quiet "git@github.com:$owner/$name.git" "$dir"; then
        echo "  WARN: clone failed for $owner/$name"; rm -rf "$dir"
        FAILED=$((FAILED+1)); FAILED_REPOS+=("$owner/$name")
    fi
}

sync_repos kylelundstedt "$GITHUB_DIR/kylelundstedt"
sync_repos IndustryVault "$GITHUB_DIR/IndustryVault"
sync_repos iv-cmg "$GITHUB_DIR/iv-cmg"
sync_repos USAA "$GITHUB_DIR/USAA"

date +%s > "$LAST_RUN_FILE"
if [[ "$FAILED" -gt 0 ]]; then
    echo "==> Done $(date) — $FAILED repo(s) FAILED: ${FAILED_REPOS[*]}"
else
    echo "==> Done $(date) — all repos synced"
fi

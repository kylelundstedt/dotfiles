#!/usr/bin/env bash
# Shared helpers for personal-mcp scheduled jobs: persistent dated logging +
# a healthchecks.io dead-man's-switch. Source this file, then:
#
#   pm_setup_logging <job>          # tee all output to a dated log, prune >30 days
#   pm_hc <job> [path] [curl-args]  # ping the job's healthcheck (no-op if unset)
#
# Healthcheck URLs live in the macOS login Keychain, one per job, so the launchd
# jobs run unattended and no secret lands in git. To enable alerting for a job,
# create a check at healthchecks.io and store its URL:
#
#   security add-generic-password -U -s "personal-mcp:<job>-healthcheck-url" \
#       -a "$USER" -w "https://hc-ping.com/<uuid>"
#
# Until a URL is stored, pm_hc is a silent no-op (logging still works). Convention:
# pm_hc <job> /start  at begin,  pm_hc <job>  on success,  pm_hc <job> /fail ...  on failure.

PM_LOGDIR="$HOME/Library/Logs/personal-mcp"

pm_setup_logging() {
    local job="$1"
    mkdir -p "$PM_LOGDIR"
    # tee keeps a dated history here while stdout still flows to the launchd log.
    exec > >(tee -a "$PM_LOGDIR/${job}-$(date +%F-%H%M%S).log") 2>&1
    find "$PM_LOGDIR" -name "${job}-*.log" -type f -mtime +30 -delete 2>/dev/null || true
}

pm_hc() {
    local job="$1"; shift
    local url
    url=$(security find-generic-password -s "personal-mcp:${job}-healthcheck-url" -w 2>/dev/null)
    [ -n "$url" ] || return 0   # no check configured -> no-op
    curl -fsS -m 10 --retry 3 "${url}${1:-}" "${@:2}" >/dev/null 2>&1 || true
}

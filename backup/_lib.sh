#!/usr/bin/env bash
# Shared helpers for the unattended jobs in this repo (tigris-backup.sh,
# sync-repos.sh, restore-drill.sh). Source this file; functions only — no side
# effects at source time. Behavior extracted byte-identical from the scripts
# (2026-07, U10); the hard-won monitoring semantics live HERE so no script can
# drift from them individually:
#
#   - job_stale_skip pings success when it skips. lastrun is only written by a
#     fully-clean run (job_mark_done), so "fresh" is exactly the monitor's
#     definition of success. A silent skip starves the check — a manual
#     afternoon run phase-shifts the nightly into the guard window (2026-07-06).
#   - job_mark_done is for CLEAN runs only. Marking a failed run arms the
#     staleness skip and the next scheduled run skips+pings success over a red
#     check (the 2026-07-04..09 flapping).
#
# See agent_docs/monitoring.md for the registry + rules.

# job_kc <service> — read a secret from the login Keychain (empty if absent).
# Never fails: absent items must not kill `set -e` callers (check-key-expiry
# died on exit 44 here, 2026-07-13) — callers test for an empty result instead.
job_kc() { security find-generic-password -s "$1" -w 2>/dev/null || true; }

# job_require_mini <job-name> — mini-only capability guard: exit 0 quietly on
# any other host (these jobs act on this machine's disks/archives/keychain).
job_require_mini() {
    if [[ "$(scutil --get LocalHostName 2>/dev/null)" != "klundstedt-mini" ]]; then
        echo "not klundstedt-mini; skipping ${1:-job}."; exit 0
    fi
}

# job_trim <string> — strip leading/trailing whitespace (pipe-manifest fields).
# Canonical trim for the provisioning scripts; install.sh keeps its own copy
# (mtrim) DELIBERATELY — the installer must stay self-contained for the
# curl|bash bootstrap phase, where no repo file exists to source yet.
job_trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

# job_hc_init <keychain-service> — resolve this job's healthchecks.io ping URL.
# No-op pinger if the item is absent (logging still works, alerting doesn't).
job_hc_init() { JOB_HC_URL=$(job_kc "$1"); }

# job_hc [path] [curl-args...] — ping the check: job_hc /start at begin, bare
# job_hc on success, job_hc /fail --data-raw "summary" on failure. Never fails
# the caller.
job_hc() { [[ -n "${JOB_HC_URL:-}" ]] && curl -fsS -m 10 --retry 3 "${JOB_HC_URL}${1:-}" "${@:2}" >/dev/null 2>&1 || true; }

# job_stale_skip <lastrun-file> <interval-secs> — returns 0 (caller should
# skip) if the last CLEAN run is fresher than the interval, pinging success
# first. Sets JOB_STALE_AGE_H for the caller's log message.
job_stale_skip() {
    local f="$1" interval="$2" now last
    [[ -f "$f" ]] || return 1
    now=$(date +%s); last=$(cat "$f" 2>/dev/null || echo 0)
    (( now - last < interval )) || return 1
    JOB_STALE_AGE_H=$(( (now - last) / 3600 ))
    job_hc
    return 0
}

# job_lock <lockdir> — take the single-instance lock (mkdir is atomic).
# Returns 1 if another instance holds it. The CALLER owns cleanup (trap).
job_lock() { mkdir "$1" 2>/dev/null; }

# job_mark_done <lastrun-file> — record a fully-clean run (and nothing else).
job_mark_done() { date +%s > "$1"; }

# job_log <logdir> — persistent dated logs (launchd's /tmp log is wiped on
# reboot); tee all output, prune >30 days.
job_log() {
    local dir="$1"; mkdir -p "$dir"
    exec > >(tee -a "$dir/$(date +%F-%H%M%S).log") 2>&1
    find "$dir" -name '*.log' -type f -mtime +30 -delete 2>/dev/null || true
}

# tigris_rclone_env — read the tigris-backup:* Keychain creds and export the
# rclone remotes shared by the nightly backup and the restore drill:
#   tigris:  S3 base (t3.storage.dev)
#   bkup:    crypt over klundstedt-mini-backup   (home + photos, IA)
#   arch:    crypt over klundstedt-mini-archive  (GLACIER_IR sources)
# Exits 1 (with FATAL) if any cred is missing. Also exports TIGRIS_STORAGE_*
# for the tigris CLI. ACL=private applies to writes only — harmless for the
# read-only drill.
tigris_rclone_env() {
    local tid tsec cpw csalt ob_pw ob_salt
    tid=$(job_kc "tigris-backup:s3-key-id"); tsec=$(job_kc "tigris-backup:s3-secret")
    cpw=$(job_kc "tigris-backup:crypt-password"); csalt=$(job_kc "tigris-backup:crypt-salt")
    if [[ -z "$tid" || -z "$tsec" || -z "$cpw" || -z "$csalt" ]]; then
        echo "FATAL: tigris-backup creds missing from Keychain"; return 1
    fi
    export RCLONE_CONFIG_TIGRIS_TYPE=s3 RCLONE_CONFIG_TIGRIS_PROVIDER=Other
    export RCLONE_CONFIG_TIGRIS_ACCESS_KEY_ID="$tid" RCLONE_CONFIG_TIGRIS_SECRET_ACCESS_KEY="$tsec"
    export RCLONE_CONFIG_TIGRIS_ENDPOINT=https://t3.storage.dev RCLONE_CONFIG_TIGRIS_REGION=auto RCLONE_CONFIG_TIGRIS_ACL=private
    ob_pw=$(rclone obscure "$cpw"); ob_salt=$(rclone obscure "$csalt")
    export RCLONE_CONFIG_BKUP_TYPE=crypt RCLONE_CONFIG_BKUP_REMOTE=tigris:klundstedt-mini-backup
    export RCLONE_CONFIG_BKUP_FILENAME_ENCRYPTION=standard RCLONE_CONFIG_BKUP_DIRECTORY_NAME_ENCRYPTION=true
    export RCLONE_CONFIG_BKUP_PASSWORD="$ob_pw" RCLONE_CONFIG_BKUP_PASSWORD2="$ob_salt"
    export RCLONE_CONFIG_ARCH_TYPE=crypt RCLONE_CONFIG_ARCH_REMOTE=tigris:klundstedt-mini-archive
    export RCLONE_CONFIG_ARCH_FILENAME_ENCRYPTION=standard RCLONE_CONFIG_ARCH_DIRECTORY_NAME_ENCRYPTION=true
    export RCLONE_CONFIG_ARCH_PASSWORD="$ob_pw" RCLONE_CONFIG_ARCH_PASSWORD2="$ob_salt"
    export TIGRIS_STORAGE_ACCESS_KEY_ID="$tid" TIGRIS_STORAGE_SECRET_ACCESS_KEY="$tsec"
}

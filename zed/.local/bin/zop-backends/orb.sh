#!/bin/bash
# zop backend: OrbStack Linux VM
# Requires: orb CLI (installed via orbstack cask)
# SSH is built in — no setup needed.

backend_list() {
    orb list 2>/dev/null | awk '{print $1}'
}

backend_start() {
    local state
    state=$(orb info "$MACHINE" 2>/dev/null | awk '/State:/{print $2}') || true
    if [[ "$state" != "running" ]]; then
        echo "Starting OrbStack VM: $MACHINE..." >&2
        orb start "$MACHINE"
        sleep 2
    fi
}

backend_ensure_ssh() {
    # OrbStack auto-configures SSH via the `orb` host in ~/.ssh/config
    echo "${MACHINE}@orb"
}

backend_list_projects() {
    remote_exec "find ~ -mindepth 1 -maxdepth 1 -type d ! -name '.*' 2>/dev/null" || true
}

backend_home() {
    echo "~"
}

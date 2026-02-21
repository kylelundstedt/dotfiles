#!/bin/bash
# zop backend: local macOS

GITHUB_DIR="$HOME/github"

backend_list() {
    # No machines for local backend
    :
}

backend_start() {
    :
}

backend_ensure_ssh() {
    # No SSH needed for local
    echo ""
}

backend_list_projects() {
    find "$GITHUB_DIR" -mindepth 2 -maxdepth 2 -type d -not -path '*/.*' 2>/dev/null | sort
}

backend_home() {
    echo "$GITHUB_DIR"
}

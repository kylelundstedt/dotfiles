#!/bin/bash
# zp backend: local macOS

GITHUB_DIR="$HOME/github"

backend_available() { return 0; }

backend_list() {
    # No machines for local backend
    :
}

backend_create() {
    die "Local backend has no machines to create"
}

backend_start() {
    :
}

backend_ensure_ssh() {
    echo ""
}

backend_list_projects() {
    find "$GITHUB_DIR" -mindepth 2 -maxdepth 2 -type d -not -path '*/.*' 2>/dev/null | sort
}

backend_clone_project() {
    local repo="$1"
    local org name dest
    org=$(dirname "$repo")
    name=$(basename "$repo")
    dest="$GITHUB_DIR/$org/$name"
    mkdir -p "$GITHUB_DIR/$org"
    git clone "git@github.com:${repo}.git" "$dest" >&2
    echo "$dest"
}

backend_home() {
    echo "$GITHUB_DIR"
}

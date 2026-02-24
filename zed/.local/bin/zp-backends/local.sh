#!/bin/bash
# zp backend: local macOS

backend_available() { return 0; }
backend_list() { :; }
backend_create() { die "Local backend has no machines to create"; }
backend_start() { :; }
backend_ensure_ssh() { echo ""; }
backend_exec() { eval "$1"; }

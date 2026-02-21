#!/bin/bash
# Open a project in Zed (editor + integrated terminal).
# Called from macOS Shortcuts or directly from terminal.
export PATH="/opt/homebrew/bin:$PATH"

# Pick a folder
dir=$(/usr/bin/osascript <<'AS'
set b to POSIX file "/Users/klundstedt/github"
set c to choose folder with prompt "Select a project:" default location b
return POSIX path of c
AS
)
[ -z "$dir" ] && exit 0

zed "$dir"

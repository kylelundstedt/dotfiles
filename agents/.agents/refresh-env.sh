#!/usr/bin/env bash
# Session-start environment refresh — shared by all agent harnesses:
#   Claude Code (SessionStart hook), Codex (SessionStart hook),
#   Shelley (new-conversation hook, via the wrapper in .config/shelley/hooks/).
#
# Purpose:
#   1. Keep the dotfiles clone current so global agent instructions (AGENTS.md /
#      CLAUDE.md, and this repo's Memory convention) are fresh at session start.
#   2. Fast-forward the working repo *only when it is completely safe* to do so,
#      so external pushes (GitHub UI, PR merges, CI, another machine) are picked
#      up without ever disturbing local work.
#
# Contract:
#   - MUST always exit 0. Shelley aborts conversation creation on non-zero exit.
#   - No-op anywhere but an exe.dev VM (the Mac is the source of truth for
#     dotfiles). Detected via /exe.dev, present on exe.dev VMs, absent on macOS.
#   - Never mutates a dirty or non-fast-forwardable working tree.
#
# Usage: refresh-env.sh [working-repo-dir]   (defaults to $PWD)
#
# This mirrors the manual "Update already-running VMs" fan-out documented in the
# repo README (git pull --ff-only) — it just runs automatically per session.

set +e

# Only act on exe.dev VMs.
[ -d /exe.dev ] || exit 0

# 1) Refresh the dotfiles clone — a pristine deployment, so pull is always
#    fast-forward-safe. Content changes take effect through the existing stow
#    symlinks; structural changes (new files/packages) still need install.sh.
if [ -d "$HOME/dotfiles/.git" ]; then
    git -C "$HOME/dotfiles" pull --ff-only --quiet 2>/dev/null
fi

# 2) Conditionally fast-forward the working repo. All guards must hold:
#    - a target dir that isn't the dotfiles clone (handled above)
#    - inside a git work tree
#    - clean working tree (no staged/unstaged/untracked-tracked changes)
#    - current branch has an upstream (so --ff-only has a defined target)
#    --ff-only then fails cleanly (and silently) if we're not behind-only.
target="${1:-$PWD}"
if [ -n "$target" ] && [ "$target" != "$HOME/dotfiles" ] \
    && git -C "$target" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if [ -z "$(git -C "$target" status --porcelain 2>/dev/null)" ] \
        && git -C "$target" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
        git -C "$target" pull --ff-only --quiet 2>/dev/null
    fi
fi

exit 0

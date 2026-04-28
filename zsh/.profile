# Shared PATH setup for all shells (bash, zsh, sh).
# Zsh sources this from .zshenv; bash reads it for login shells.

mkdir -p "$HOME/.local/bin"

export PATH="$HOME/.local/bin:$HOME/.atuin/bin:$PATH"
export PATH="$PATH:$HOME/go/bin"

# Tell Claude Code's permission UI it's running in a sandboxed env so the
# "Bypass Permissions" option becomes available in Zed's agent selector.
export IS_SANDBOX=1

command -v fnm >/dev/null && eval "$(fnm env)"

# Export gh's stored token so tools that don't read ~/.config/gh/hosts.yml
# (Ruff LSP, npm, curl) get the 5000/hr authenticated rate limit.
if [ -z "${GITHUB_TOKEN:-}" ] && command -v gh >/dev/null 2>&1; then
    GITHUB_TOKEN="$(gh auth token 2>/dev/null)" && export GITHUB_TOKEN
fi

# Tool-managed env (cargo, atuin)
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
[ -f "$HOME/.atuin/bin/env" ] && . "$HOME/.atuin/bin/env"

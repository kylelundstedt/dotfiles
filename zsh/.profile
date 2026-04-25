# Shared PATH setup for all shells (bash, zsh, sh).
# Zsh sources this from .zshenv; bash reads it for login shells.

mkdir -p "$HOME/.local/bin"

export PATH="$HOME/.local/bin:$HOME/.atuin/bin:$PATH"
export PATH="$PATH:$HOME/go/bin"

# Tell Claude Code's permission UI it's running in a sandboxed env so the
# "Bypass Permissions" option becomes available in Zed's agent selector.
export IS_SANDBOX=1

command -v fnm >/dev/null && eval "$(fnm env)"

# Tool-managed env (cargo, atuin)
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
[ -f "$HOME/.atuin/bin/env" ] && . "$HOME/.atuin/bin/env"

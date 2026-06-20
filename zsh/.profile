# Shared PATH setup for all shells (bash, zsh, sh).
# Zsh sources this from .zshenv; bash reads it for login shells.

mkdir -p "$HOME/.local/bin"

export PATH="$HOME/.local/bin:$HOME/.atuin/bin:$PATH"
export PATH="$PATH:$HOME/go/bin"

# Tell Claude Code's permission UI it's running in a sandboxed env so the
# "Bypass Permissions" option becomes available in Zed's agent selector.
export IS_SANDBOX=1

command -v fnm >/dev/null && eval "$(fnm env)"

# msgvault email archive lives under ~/archives/email (consolidated layout) rather
# than the default ~/.msgvault. Only set where that archive exists (klundstedt-mini).
[ -d "$HOME/archives/email" ] && export MSGVAULT_HOME="$HOME/archives/email"

# Export gh's stored token so tools that don't read ~/.config/gh/hosts.yml
# (Ruff LSP, npm, curl) get the 5000/hr authenticated rate limit.
# Side effect: `gh auth status` shows GITHUB_TOKEN as the active account
# above the keyring entry — that's gh being accurate (env var wins), not
# a bug. Stale-token caveat: long-running shells keep the env value until
# restart, so `gh auth refresh` in one shell won't propagate to others.
# install.sh has the same logic at the top; keep them in sync.
if [ -z "${GITHUB_TOKEN:-}" ] && command -v gh >/dev/null 2>&1; then
    GITHUB_TOKEN="$(gh auth token 2>/dev/null)" && export GITHUB_TOKEN
fi

# Tool-managed env (cargo, atuin)
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
[ -f "$HOME/.atuin/bin/env" ] && . "$HOME/.atuin/bin/env"

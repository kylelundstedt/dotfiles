# Minimal environment for all zsh sessions (interactive + non-interactive SSH).
# Keep this light — heavy init (completions, prompts, etc.) stays in .zshrc.

mkdir -p "$HOME/.local/bin"

export PATH="$HOME/.local/bin:$HOME/.atuin/bin:$PATH"
export PATH="$PATH:$HOME/go/bin"

command -v fnm >/dev/null && eval "$(fnm env)"

#
# Executes commands at the start of an interactive session.
#

if command -v zed >/dev/null 2>&1; then
    export EDITOR="zed --wait"
elif command -v code >/dev/null 2>&1; then
    export EDITOR="code --wait"
elif command -v micro >/dev/null 2>&1; then
    export EDITOR="micro"
else
    export EDITOR="nano"
fi

if type brew &>/dev/null; then
    FPATH=$(brew --prefix)/share/zsh-completions:$FPATH
    autoload -Uz compinit
    compinit -u
fi

export NODE_OPTIONS=--max-old-space-size=65536

if [[ $(uname) == "Darwin" ]]; then
    export SSH_AUTH_SOCK=~/Library/Group\ Containers/2BUA8C4S2C.com.1password/t/agent.sock
fi

# Enable git commit signing when SSH agent is forwarded (Linux VMs via Tailscale)
if [[ -n "${SSH_AUTH_SOCK:-}" ]] && ! git config commit.gpgsign >/dev/null 2>&1; then
    git config --file ~/.gitconfig_local commit.gpgsign true
fi

command -v starship >/dev/null && eval "$(starship init zsh)"
command -v atuin >/dev/null && eval "$(atuin init zsh)"
command -v uv >/dev/null && eval "$(uv generate-shell-completion zsh)"
command -v uvx >/dev/null && eval "$(uvx --generate-shell-completion zsh)"
command -v direnv >/dev/null && eval "$(direnv hook zsh)"

# Initialize zoxide
command -v zoxide >/dev/null && eval "$(zoxide init zsh)"

# fzf configuration
[ -f ~/.fzf.zsh ] && source ~/.fzf.zsh
export FZF_DEFAULT_OPTS="--height 40% --layout=reverse --border --margin=1 --padding=1"

# Shortcuts for common commands
BAT_BIN=""
if command -v bat >/dev/null 2>&1; then
    BAT_BIN="bat"
elif command -v batcat >/dev/null 2>&1; then
    BAT_BIN="batcat"
    alias bat='batcat'
fi
[ -n "$BAT_BIN" ] && alias cat="$BAT_BIN --paging never --theme DarkNeon --style plain"
alias g='git'
alias ga='git add'
alias gb='git branch'
alias gc='git commit'
alias gca='git commit --amend'
alias gcb='git checkout -b'  # Create and switch to a new branch
alias gcl='git clone'
alias gcm='git checkout main'
alias gco='git checkout'
alias gfa='git fetch --all'
alias gl='git log --oneline --graph --decorate'
alias gpl='git pull'
alias gps='git push'
alias gpsf='git push --force'
alias gs='git status'
alias gup='git fetch --all && git pull --rebase'  # Fetch and rebase
alias claude='claude --dangerously-skip-permissions'
alias codex='codex --dangerously-bypass-approvals-and-sandbox'
if [[ "$(uname)" == "Darwin" ]]; then
    alias ls='ls -G'
fi
alias la='ls -lah'
alias mpull="find . -mindepth 1 -maxdepth 1 -type d -print -exec git -C {} pull --ff-only \;"

# ~/.zshrc
export CARAPACE_BRIDGES='zsh,fish,bash,inshellisense' # optional
zstyle ':completion:*' format $'\e[2;37mCompleting %d\e[m'
command -v carapace >/dev/null && source <(carapace _carapace)
zstyle ':completion:*:git:*' group-order 'main commands' 'alias commands' 'external commands'

### 1Password ###
# GitHub PATs for MCP servers are fetched from 1Password at runtime via wrapper scripts.
# See: ~/dotfiles/agents/.agents/mcp/bin/

# Added by LM Studio CLI (lms)
export PATH="$PATH:/Users/klundstedt/.lmstudio/bin"
# End of LM Studio CLI section


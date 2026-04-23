#!/bin/bash
set -euo pipefail

# --- Args ---
INSTALL_APPS=false
DRY_RUN=false
SKIP_STOW=false
SKIP_AGENTS=false
TAILSCALE_SSH=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --apps)           INSTALL_APPS=true; shift ;;
        --dry-run)        DRY_RUN=true; shift ;;
        --no-prompt)      shift ;;  # accepted for backwards compat, no longer needed
        --skip-stow)      SKIP_STOW=true; shift ;;
        --skip-agents)    SKIP_AGENTS=true; shift ;;
        --tailscale-ssh)  TAILSCALE_SSH=true; shift ;;
        *)
            echo "Usage: $0 [--apps] [--dry-run] [--no-prompt] [--skip-stow] [--skip-agents] [--tailscale-ssh]"
            exit 1
            ;;
    esac
done

# --- Self-bootstrap ---
# When piped via `curl | bash`, the script isn't inside the dotfiles repo.
# Detect this, install git, clone the repo, and re-exec from the real copy.
DOTFILES_REPO="https://github.com/kylelundstedt/dotfiles.git"
DOTFILES_TARGET="$HOME/dotfiles"

if [[ "${_DOTFILES_BOOTSTRAPPED:-}" != "1" ]]; then
    # Check if we're running from inside the dotfiles repo (AGENTS.md is a reliable marker).
    # When piped via curl|bash, BASH_SOURCE is empty and $0 is "bash" — treat that as not-in-repo.
    script_dir=""
    if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || script_dir=""
    fi
    if [[ -z "$script_dir" || ! -f "$script_dir/AGENTS.md" ]]; then
        echo "=== Bootstrap ==="
        # Ensure git is available
        if ! command -v git >/dev/null 2>&1; then
            if [[ "$OSTYPE" == "darwin"* ]]; then
                echo "Xcode Command Line Tools (includes git) are required. Install them and re-run."
                exit 1
            else
                sudo_cmd="sudo"; [[ $EUID -eq 0 ]] && sudo_cmd=""
                $sudo_cmd apt-get update -qq 2>/dev/null || true
                $sudo_cmd apt-get install -y -qq git curl >/dev/null 2>&1
            fi
        fi
        # Clone or pull
        if [[ -d "$DOTFILES_TARGET/.git" ]]; then
            echo "  Updating $DOTFILES_TARGET..."
            git -C "$DOTFILES_TARGET" pull --ff-only --quiet 2>/dev/null || true
        else
            echo "  Cloning to $DOTFILES_TARGET..."
            git clone --quiet "$DOTFILES_REPO" "$DOTFILES_TARGET"
        fi
        # Re-exec from the cloned copy
        export _DOTFILES_BOOTSTRAPPED=1
        exec "$DOTFILES_TARGET/install.sh" "$@"
    fi
fi

# --- OS detection ---
if [[ "$OSTYPE" == "darwin"* ]]; then
    OS="macos"
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    OS="linux"
else
    echo "Unsupported OS"; exit 1
fi

IS_INTERACTIVE=false
[[ -t 0 && -t 1 ]] && IS_INTERACTIVE=true

SUDO="sudo"
[[ $EUID -eq 0 ]] && SUDO=""

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
LOCAL_BIN="$HOME/.local/bin"
mkdir -p "$LOCAL_BIN"
export PATH="$LOCAL_BIN:$PATH"

# --- Helpers ---
need() { ! command -v "$1" >/dev/null 2>&1; }

# Set GITHUB_TOKEN from gh CLI if available (raises rate limit from 60 to 5000/hr)
if [[ -z "${GITHUB_TOKEN:-}" ]] && command -v gh >/dev/null 2>&1; then
    GITHUB_TOKEN=$(gh auth token 2>/dev/null) || true
    [[ -n "$GITHUB_TOKEN" ]] && export GITHUB_TOKEN
fi

# Fetch latest GitHub release asset, extract, and place binary in ~/.local/bin.
# Usage: install_github_binary <owner/repo> <asset_pattern> <binary_name> [<path_inside_archive>]
#   asset_pattern: grep -E pattern to match the asset filename (use ARCH/OS placeholders before calling)
#   binary_name: final name in ~/.local/bin
#   path_inside_archive: optional path to the binary inside a tar/zip (default: same as binary_name)
install_github_binary() {
    local repo="$1" pattern="$2" bin_name="$3"
    local inner_path="${4:-$bin_name}"
    local tmp asset_url asset_name api_response
    # Resolve latest release asset URL (retry once on 403 rate-limit)
    local gh_api_url="https://api.github.com/repos/${repo}/releases/latest"
    local attempt
    for attempt in 1 2; do
        if [[ -n "${GITHUB_TOKEN:-}" ]]; then
            api_response=$(curl -fsSL -H "Authorization: token $GITHUB_TOKEN" "$gh_api_url" 2>&1) && break
        else
            api_response=$(curl -fsSL "$gh_api_url" 2>&1) && break
        fi
        [[ $attempt -eq 1 ]] && sleep $((RANDOM % 5 + 2))
    done
    asset_url=$(echo "$api_response" \
        | grep -oE "\"browser_download_url\": \"[^\"]+\"" \
        | grep -E "$pattern" \
        | head -1 \
        | sed 's/"browser_download_url": "//;s/"//')
    if [[ -z "$asset_url" ]]; then
        echo "  [!] $bin_name: no matching release asset"; return 1
    fi
    asset_name="${asset_url##*/}"
    tmp=$(mktemp -d)

    local -a dl_opts=(-fsSL)
    [[ -n "${GITHUB_TOKEN:-}" ]] && dl_opts+=(-H "Authorization: token $GITHUB_TOKEN")
    if curl "${dl_opts[@]}" "$asset_url" -o "$tmp/$asset_name"; then
        case "$asset_name" in
            *.tar.gz|*.tgz) tar -xzf "$tmp/$asset_name" -C "$tmp" ;;
            *.zip)          unzip -qo "$tmp/$asset_name" -d "$tmp" ;;
            *)              chmod +x "$tmp/$asset_name"; if [[ "$asset_name" != "$inner_path" ]]; then mv "$tmp/$asset_name" "$tmp/$inner_path"; fi ;;
        esac
        # Find the binary — check inner_path first, then search
        if [[ -f "$tmp/$inner_path" ]]; then
            mv "$tmp/$inner_path" "$LOCAL_BIN/$bin_name"
        else
            local found
            found=$(find "$tmp" -name "$bin_name" -type f | head -1)
            if [[ -n "$found" ]]; then
                mv "$found" "$LOCAL_BIN/$bin_name"
            else
                echo "  [!] $bin_name: binary not found in archive"; rm -rf "$tmp"; return 1
            fi
        fi
        chmod +x "$LOCAL_BIN/$bin_name"
        echo "  [+] $bin_name"
    else
        echo "  [!] $bin_name: download failed"
    fi
    rm -rf "$tmp"
}

# --- install_system_deps ---
install_system_deps() {
    echo "=== System dependencies ==="
    if [[ "$OS" == "linux" ]]; then
        echo "Installing system packages via apt..."
        $SUDO apt-get update -qq 2>/dev/null || true
        $SUDO apt-get install -y -qq stow zsh git curl unzip cron
    elif [[ "$OS" == "macos" ]]; then
        if need brew; then
            echo "Homebrew is required on macOS. Install from https://brew.sh and re-run."
            exit 1
        fi
        brew list stow &>/dev/null || brew install stow
    fi
}

# --- install_cli_tools ---
install_cli_tools() {
    echo ""
    echo "=== CLI tools ==="
    local arch
    arch=$(uname -m)

    # Platform strings for GitHub release asset matching
    # target_triple: used by bat, ripgrep (Rust-style: aarch64-apple-darwin, x86_64-unknown-linux)
    # gh_os/gh_arch: used by gh, fzf, jq, yq, duckdb, carapace (go-style: darwin/amd64, linux/arm64)
    local target_triple gh_os gh_arch duckdb_os gh_cli_os
    case "$OS-$arch" in
        macos-arm64)   target_triple="aarch64-apple-darwin"; gh_os="darwin"; gh_arch="arm64"; duckdb_os="osx"; gh_cli_os="macOS" ;;
        macos-x86_64)  target_triple="x86_64-apple-darwin";  gh_os="darwin"; gh_arch="amd64"; duckdb_os="osx"; gh_cli_os="macOS" ;;
        linux-x86_64)  target_triple="x86_64-unknown-linux";  gh_os="linux";  gh_arch="amd64"; duckdb_os="linux"; gh_cli_os="linux" ;;
        linux-aarch64) target_triple="aarch64-unknown-linux"; gh_os="linux";  gh_arch="arm64"; duckdb_os="linux"; gh_cli_os="linux" ;;
        *) echo "  [!] Unsupported platform: $OS-$arch"; return 1 ;;
    esac

    # Always install all tools to ~/.local/bin — no `need` checks.
    # This ensures identical versions across macOS and Linux regardless of
    # what the system or brew already has. ~/.local/bin is first on PATH.
    local pids=()
    local fnm_asset
    case "$OS-$arch" in
        macos-*)       fnm_asset="fnm-macos" ;;
        linux-aarch64) fnm_asset="fnm-arm64" ;;
        linux-x86_64)  fnm_asset="fnm-linux" ;;
    esac

    # Curl install scripts
    (curl -fsSL https://starship.rs/install.sh | sh -s -- --yes --bin-dir="$LOCAL_BIN" >/dev/null 2>&1 && echo "  [+] starship" || echo "  [!] starship failed") &
    pids+=($!)
    (curl -fsSL https://astral.sh/uv/install.sh | env CARGO_HOME="$HOME/.local" sh >/dev/null 2>&1 && echo "  [+] uv" || echo "  [!] uv failed") &
    pids+=($!)
    (curl -fsSL https://github.com/atuinsh/atuin/releases/latest/download/atuin-installer.sh | sh -s -- --no-modify-path >/dev/null 2>&1 && echo "  [+] atuin" || echo "  [!] atuin failed") &
    pids+=($!)
    local direnv_os; case "$OS" in macos) direnv_os="darwin" ;; linux) direnv_os="linux" ;; esac
    (install_github_binary "direnv/direnv" "direnv\\.${direnv_os}-${gh_arch}\"$" "direnv" "direnv.${direnv_os}-${gh_arch}") &
    pids+=($!)
    (install_github_binary "ajeetdsouza/zoxide" "zoxide-.*-${target_triple}.*\\.tar\\.gz" "zoxide") &
    pids+=($!)
    local tigris_arch; case "$arch" in arm64|aarch64) tigris_arch="arm64" ;; x86_64) tigris_arch="x64" ;; esac
    (install_github_binary "tigrisdata/cli" "tigris-${direnv_os}-${tigris_arch}\\.tar\\.gz" "tigris" "tigris-${direnv_os}-${tigris_arch}") &
    pids+=($!)
    # archil: CLI on Linux, macOS app installed separately (interactive prompt)
    if [[ "$OS" == "linux" ]]; then
        (if need archil; then curl -fsSL https://archil.com/install | sh >/dev/null 2>&1 && echo "  [+] archil" || echo "  [!] archil failed"; fi) &
        pids+=($!)
    fi
    (install_github_binary "Schniz/fnm" "${fnm_asset}\\.zip" "fnm" "fnm") &
    pids+=($!)

    # GitHub release binaries
    (install_github_binary "sharkdp/bat" "bat-v.*-${target_triple}.*\\.tar\\.gz" "bat") &
    pids+=($!)
    (install_github_binary "junegunn/fzf" "fzf-.*-${gh_os}_${gh_arch}\\.tar\\.gz" "fzf" "fzf") &
    pids+=($!)
    (install_github_binary "BurntSushi/ripgrep" "ripgrep-.*-${target_triple}.*\\.tar\\.gz" "rg") &
    pids+=($!)
    local jq_os; case "$OS" in macos) jq_os="macos" ;; linux) jq_os="linux" ;; esac
    (install_github_binary "jqlang/jq" "jq-${jq_os}-${gh_arch}\"$" "jq" "jq-${jq_os}-${gh_arch}") &
    pids+=($!)
    (install_github_binary "mikefarah/yq" "yq_${gh_os}_${gh_arch}\"$" "yq" "yq_${gh_os}_${gh_arch}") &
    pids+=($!)
    (install_github_binary "cli/cli" "gh_.*_${gh_cli_os}_${gh_arch}\\.(tar\\.gz|zip)" "gh") &
    pids+=($!)
    (install_github_binary "duckdb/duckdb" "duckdb_cli-${duckdb_os}-${gh_arch}\\.zip" "duckdb" "duckdb") &
    pids+=($!)
    (install_github_binary "carapace-sh/carapace-bin" "carapace-bin_.*_${gh_os}_${gh_arch}\\.tar\\.gz" "carapace" "carapace") &
    pids+=($!)
    (install_github_binary "stephenleo/cship" "cship-${target_triple}" "cship" "cship-${target_triple}") &
    pids+=($!)

    # Wait for all parallel installs
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
}

# --- install_python_clis ---
# Python-based CLIs installed via `uv tool install` (binaries land in ~/.local/bin).
# Runs after install_cli_tools so uv is guaranteed available.
install_python_clis() {
    echo ""
    echo "=== Python CLIs (uv tool) ==="
    if need uv; then
        echo "  [!] uv not available, skipping"
        return 0
    fi
    # snowflake-cli provides the `snow` command
    if command -v snow >/dev/null 2>&1; then
        uv tool upgrade snowflake-cli >/dev/null 2>&1 && echo "  [+] snow (upgraded)" || echo "  [+] snow (up to date)"
    else
        uv tool install snowflake-cli >/dev/null 2>&1 && echo "  [+] snow" || echo "  [!] snowflake-cli failed"
    fi
}

# --- setup_node ---
setup_node() {
    echo ""
    echo "=== Node (via fnm) ==="
    if need fnm; then
        echo "  [!] fnm not available, skipping node setup"
        return 0
    fi
    eval "$(fnm env)"
    if need node; then
        fnm install --lts >/dev/null 2>&1 && echo "  [+] node $(node --version)" || echo "  [!] node install failed"
    else
        echo "  node $(node --version) already installed"
    fi

    # Create stable symlinks in ~/.local/bin so node/npm/npx are available
    # without eval "$(fnm env)" — needed for shells that don't source .zshenv
    # (e.g. Claude Code on remote containers).
    local fnm_default="$HOME/.local/share/fnm/aliases/default/bin"
    if [[ -d "$fnm_default" ]]; then
        for bin in node npm npx corepack; do
            [[ -e "$fnm_default/$bin" ]] && ln -sf "$fnm_default/$bin" "$LOCAL_BIN/$bin"
        done
    fi
}

# --- setup_git ---
setup_git() {
    echo ""
    echo "=== Git configuration ==="
    local git_config_local="$DOTFILES_DIR/git/.gitconfig_local"
    local os_local="$HOME/.gitconfig_os_local"

    # Write OS include
    local include_path
    case "$OS" in
        macos) include_path="~/.gitconfig_macos" ;;
        linux) include_path="~/.gitconfig_linux" ;;
    esac
    cat > "$os_local" <<EOF
[include]
    path = $include_path
EOF

    # SSH config
    local ssh_config="$HOME/.ssh/config"
    mkdir -p "$HOME/.ssh/sockets"
    chmod 700 "$HOME/.ssh"
    touch "$ssh_config"

    if [[ "$OS" == "macos" ]]; then
        # Canonicalize MagicDNS short names to FQDNs (must be at top of config)
        if ! grep -q 'CanonicalizeHostname' "$ssh_config" 2>/dev/null && tailscale status >/dev/null 2>&1; then
            local tailnet_domain
            tailnet_domain=$(tailscale status --json 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin)['Self']['DNSName']; parts=d.rstrip('.').split('.'); print('.'.join(parts[1:]))" 2>/dev/null)
            if [[ -n "$tailnet_domain" ]]; then
                local tmp_config
                tmp_config=$(mktemp)
                cat > "$tmp_config" <<SSHEOF
CanonicalizeHostname yes
CanonicalDomains $tailnet_domain
CanonicalizeMaxDots 0

SSHEOF
                cat "$ssh_config" >> "$tmp_config"
                mv "$tmp_config" "$ssh_config"
                chmod 600 "$ssh_config"
                echo "  [+] SSH hostname canonicalization for $tailnet_domain"
            fi
        fi

        # SSH multiplexing for GitHub
        if ! grep -q 'Host github.com' "$ssh_config" 2>/dev/null; then
            cat >> "$ssh_config" <<'SSHEOF'

Host github.com
  ControlMaster auto
  ControlPath ~/.ssh/sockets/%r@%h-%p
  ControlPersist 600
SSHEOF
            echo "  [+] SSH multiplexing for github.com"
        fi

        # SSH multiplexing for exe.dev lobby (avoids silent per-IP rate limit)
        if ! grep -q '^Host exe.dev$' "$ssh_config" 2>/dev/null; then
            cat >> "$ssh_config" <<'SSHEOF'

Host exe.dev
  ControlMaster auto
  ControlPath ~/.ssh/sockets/%r@%h-%p
  ControlPersist 600
SSHEOF
            echo "  [+] SSH multiplexing for exe.dev"
        fi

        # Forward SSH agent to Tailscale VMs
        if ! grep -q 'ForwardAgent yes' "$ssh_config" 2>/dev/null; then
            cat >> "$ssh_config" <<'SSHEOF'

Host *.ts.net
  ForwardAgent yes
SSHEOF
            echo "  [+] SSH agent forwarding for *.ts.net"
        fi

        # 1Password SSH agent
        local op_agent_sock="$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
        if [[ -S "$op_agent_sock" ]] && ! grep -q 'IdentityAgent' "$ssh_config" 2>/dev/null; then
            cat >> "$ssh_config" <<'SSHEOF'

Host *
  IdentityAgent "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
SSHEOF
            echo "  [+] 1Password SSH agent"
        fi
    fi

    if [[ "$OS" == "linux" ]]; then
        # GitHub SSH over port 443 (port 22 blocked on Apple Containers)
        if ! grep -q 'Host github.com' "$ssh_config" 2>/dev/null; then
            cat >> "$ssh_config" <<'SSHEOF'

Host github.com
  Hostname ssh.github.com
  Port 443
  User git
SSHEOF
            echo "  [+] GitHub SSH over port 443"
        fi

        # Add GitHub known host (idempotent)
        if ! grep -q 'ssh.github.com' "$HOME/.ssh/known_hosts" 2>/dev/null; then
            ssh-keyscan -p 443 ssh.github.com >> "$HOME/.ssh/known_hosts" 2>/dev/null
            echo "  [+] GitHub known host"
        fi
    fi

    # Ensure local config exists
    touch "$git_config_local"
    if [[ -s "$git_config_local" ]]; then
        echo "  Git user config already set"
    elif [[ "$IS_INTERACTIVE" == true ]]; then
        # Prompt for name/email
        echo "  Git user not configured yet."
        read -rp "  Git user name: " git_name
        read -rp "  Git email: " git_email
        if [[ -n "$git_name" && -n "$git_email" ]]; then
            cat > "$git_config_local" <<EOF
[user]
name = $git_name
email = $git_email
EOF
            echo "  [+] Wrote git/.gitconfig_local"
        fi
    elif [[ "$OS" == "linux" ]]; then
        # Non-interactive Linux VM — use personal identity as default.
        # Work repos under ~/github/klundstedt/ pick up .gitconfig_work
        # via includeIf in .gitconfig (stowed).
        cat > "$git_config_local" <<'EOF'
[user]
name = Kyle G. Lundstedt
email = kyle@lundstedt.us
EOF
        mkdir -p "$HOME/github/kylelundstedt" "$HOME/github/klundstedt"
        echo "  [+] Wrote git/.gitconfig_local (default: personal)"
    else
        echo "  Skipping git user setup (non-interactive). Run install.sh interactively to configure."
    fi

    # Commit signing is enabled at login time by .zshrc when SSH agent is forwarded
}

# --- set_shell ---
set_shell() {
    local desired_shell
    desired_shell="$(command -v zsh || true)"
    if [[ -n "$desired_shell" && "$SHELL" != "$desired_shell" ]]; then
        if [[ "$(id -u)" -eq 0 ]]; then
            chsh -s "$desired_shell" 2>/dev/null || echo "  Note: could not change shell to zsh"
        else
            sudo chsh -s "$desired_shell" "$(whoami)" 2>/dev/null || chsh -s "$desired_shell" 2>/dev/null || echo "  Note: could not change shell to zsh"
        fi
    fi
}

# --- run_stow ---
run_stow() {
    if [[ "$SKIP_STOW" == true ]]; then
        echo "  Skipping stow."
        return 0
    fi

    echo ""
    echo "=== Stow ==="

    # Always stow these
    local packages=("git" "zsh" "starship" "agents")

    # Platform-specific
    if [[ "$OS" == "macos" ]]; then
        packages+=("1Password" "ghostty" "launchd" "vscode" "zed" "homebrew" "ssh")
    else
        packages+=("aws" "ssh")
    fi

    # Backup files that conflict with the agents stow package
    for f in "$HOME/.claude/settings.json" "$HOME/.claude/CLAUDE.md" "$HOME/.codex/AGENTS.md" "$HOME/.agents/AGENTS.md"; do
        if [[ -f "$f" && ! -L "$f" ]]; then
            mv "$f" "${f}.pre-dotfiles.$(date +%Y%m%d%H%M%S)"
            echo "  Backed up $f"
        fi
    done

    # In non-interactive Linux, back up shell config files that containers provide
    if [[ "$OS" == "linux" && "$IS_INTERACTIVE" == false ]]; then
        for f in .zshrc .bashrc .profile .gitconfig; do
            if [[ -f "$HOME/$f" && ! -L "$HOME/$f" ]]; then
                mv "$HOME/$f" "$HOME/${f}.pre-dotfiles.$(date +%Y%m%d%H%M%S)"
            fi
        done
    fi

    echo "  Packages: ${packages[*]}"
    for folder in "${packages[@]}"; do
        if [[ "$DRY_RUN" == true ]]; then
            stow --no-folding -R -n -t "$HOME" "$folder"
        elif [[ "$OS" == "macos" || "$IS_INTERACTIVE" == true ]]; then
            stow --adopt --no-folding -R -t "$HOME" "$folder"
        else
            stow --no-folding -R -t "$HOME" "$folder"
        fi
    done

    # Ensure 1Password config dir permissions
    if [[ "$OS" == "macos" ]]; then
        mkdir -p "$HOME/.config/op"
        chmod 700 "$HOME/.config/op"
    fi
}

# --- setup_agents ---
setup_agents() {
    echo ""
    echo "=== Agents ==="

    # Claude Code CLI (native installer, npm fallback for arm64 Linux)
    if need claude && [[ ! -f "$LOCAL_BIN/claude" ]]; then
        echo "  Installing Claude Code CLI..."
        if curl -fsSL https://claude.ai/install.sh | bash >/dev/null 2>&1 && command -v claude >/dev/null 2>&1; then
            echo "  [+] Claude Code"
        elif command -v npm >/dev/null 2>&1; then
            echo "  Native installer failed, trying npm..."
            npm install -g @anthropic-ai/claude-code >/dev/null 2>&1 && echo "  [+] Claude Code (npm)" || echo "  [!] Claude Code install failed"
        else
            echo "  [!] Claude Code install failed"
        fi
    fi

    # Codex CLI
    if command -v npm >/dev/null 2>&1 && need codex; then
        echo "  Installing Codex CLI..."
        npm install -g @openai/codex >/dev/null 2>&1 || echo "  [!] Codex install failed"
    fi

    # 1Password CLI (Linux only — macOS gets it from Brewfile cask)
    if need op && [[ "$OS" == "linux" ]]; then
        echo "  Installing 1Password CLI..."
        local op_arch
        case "$(uname -m)" in
            x86_64)  op_arch="amd64" ;;
            aarch64) op_arch="arm64" ;;
            *) echo "  [!] 1Password CLI: unsupported arch $(uname -m)"; op_arch="" ;;
        esac
        if [[ -n "$op_arch" ]]; then
            local op_tmp op_version
            op_tmp=$(mktemp -d)
            op_version=$(curl -sS "https://app-updates.agilebits.com/check/1/0/CLI2/en/0.0.0/N" 2>/dev/null | grep -oE '"version":"[^"]+"' | head -1 | cut -d'"' -f4 || echo "2.32.1")
            if curl -sSfo "$op_tmp/op.zip" "https://cache.agilebits.com/dist/1P/op2/pkg/v${op_version}/op_linux_${op_arch}_v${op_version}.zip"; then
                unzip -qo "$op_tmp/op.zip" op -d "$LOCAL_BIN" && chmod +x "$LOCAL_BIN/op" && echo "  [+] 1Password CLI (v${op_version})" || echo "  [!] 1Password CLI: extract failed"
            else
                echo "  [!] 1Password CLI: download failed"
            fi
            rm -rf "$op_tmp"
        fi
    fi

    # MCP servers (remote HTTP transport)
    echo "  Configuring MCP servers..."
    local op_configured=false
    if command -v op >/dev/null 2>&1 && [[ -n "$(op account list 2>/dev/null || true)" ]]; then
        op_configured=true
    fi

    # --- Claude Code ---
    if command -v claude >/dev/null 2>&1; then
        # Remove stale servers from previous installations
        for old in dlt github-home github-work motherduck readwise tigris; do
            claude mcp remove --scope user "$old" >/dev/null 2>&1 || true
        done

        # OAuth servers (browser auth on first use)
        claude mcp add --transport http --scope user motherduck https://api.motherduck.com/mcp >/dev/null 2>&1 || true
        claude mcp add --transport http --scope user tigris https://mcp.storage.dev/mcp >/dev/null 2>&1 || true
        claude mcp add --transport http --scope user readwise https://mcp2.readwise.io/mcp >/dev/null 2>&1 || true

        # GitHub servers (PAT from 1Password)
        if [[ "$op_configured" == true ]]; then
            local pat_home pat_work
            pat_home=$(op read "op://Private/GitHub PAT Home/token" --account lundstedts.1password.com 2>/dev/null) || true
            pat_work=$(op read "op://Employee/GitHub PAT IV/token" --account industryvault.1password.com 2>/dev/null) || true
            [[ -n "$pat_home" ]] && claude mcp add-json --scope user github-home \
                "{\"type\":\"http\",\"url\":\"https://api.githubcopilot.com/mcp/\",\"headers\":{\"Authorization\":\"Bearer $pat_home\"}}" >/dev/null 2>&1 || true
            [[ -n "$pat_work" ]] && claude mcp add-json --scope user github-work \
                "{\"type\":\"http\",\"url\":\"https://api.githubcopilot.com/mcp/\",\"headers\":{\"Authorization\":\"Bearer $pat_work\"}}" >/dev/null 2>&1 || true
        else
            echo "  Skipping GitHub MCP servers (1Password not configured)"
        fi
    fi

    # --- Codex ---
    if command -v codex >/dev/null 2>&1; then
        # Remove stale servers from previous installations
        for old in dlt github-home github-work motherduck readwise tigris; do
            codex mcp remove "$old" >/dev/null 2>&1 || true
        done
    fi

    echo "  [+] MCP servers configured"

    # Skills
    if command -v npx >/dev/null 2>&1; then
        echo "  Installing agent skills..."
        npx -y skills add -g -y matsonj/mviz >/dev/null 2>&1 || true
        npx -y skills add -g -y vercel-labs/skills -s find-skills >/dev/null 2>&1 || true
        npx -y skills add -g -y tigrisdata/tigris-agents-plugins >/dev/null 2>&1 || true
        npx -y skills add -g -y duckdb/duckdb-skills >/dev/null 2>&1 || true
        npx -y skills add -g -y motherduckdb/agent-skills >/dev/null 2>&1 || true
        npx -y skills add -g -y posit-dev/skills -s quarto-authoring brand-yml >/dev/null 2>&1 || true
        npx -y skills add -g -y marimo-team/skills -s marimo-notebook marimo-batch >/dev/null 2>&1 || true
        npx -y skills add -g -y kylelundstedt/dotfiles -s bootstrap-project data-pipelines sprites-dev exe-dev >/dev/null 2>&1 || true
        # apple-containers is private — installed locally on macOS only (npx -y skills add -g -y . -s apple-containers)
        # archil-guide — no GitHub repo, download skill file directly
        mkdir -p "$HOME/.agents/skills/archil-guide"
        curl -fsSL https://archil.com/skill.md -o "$HOME/.agents/skills/archil-guide/SKILL.md" 2>/dev/null || true
        for agent_dir in "$HOME/.claude/skills" "$HOME/.codex/skills"; do
            [ -d "$agent_dir" ] && ln -sf "../../.agents/skills/archil-guide" "$agent_dir/archil-guide" 2>/dev/null || true
        done
        echo "  [+] Skills installed"
    else
        echo "  [!] npx not found, skipping skill installation"
    fi

    if ! command -v op >/dev/null 2>&1; then
        echo ""
        echo "  Note: 1Password CLI is required at runtime for secret-backed MCP servers."
    fi
}

# --- setup_tailscale ---
setup_tailscale() {
    echo ""
    echo "=== Tailscale ==="

    if [[ "$OS" == "macos" ]]; then
        # On macOS, open-source tailscaled is needed for incoming Tailscale SSH.
        # Use --tailscale-ssh on first run; subsequent runs auto-detect the brew formula.
        if brew list --formula tailscale &>/dev/null || [[ "$TAILSCALE_SSH" == true ]]; then
            # Open-source tailscale via Homebrew formula (not the cask/App Store app)
            if ! brew list --formula tailscale &>/dev/null; then
                echo "  Installing open-source tailscale (brew formula)..."
                brew install tailscale
                echo "  [+] tailscale (open-source)"
            else
                echo "  Open-source tailscale already installed"
            fi

            # Start tailscaled as a system daemon (needs root for real tun device)
            if ! pgrep -x tailscaled >/dev/null 2>&1; then
                if sudo -n true 2>/dev/null; then
                    sudo brew services start tailscale 2>/dev/null || true
                    sleep 2
                    echo "  [+] tailscaled started via brew services"
                else
                    echo "  [!] tailscaled not running. Run: sudo brew services start tailscale"
                fi
            fi

            # Authenticate with SSH enabled
            if sudo -n true 2>/dev/null; then
                local ts_key="${TS_AUTHKEY:-}"
                if [[ -z "$ts_key" ]] && command -v op >/dev/null 2>&1; then
                    ts_key=$(op read "op://Employee/Tailscale - iv-internal-dev/credential" --account industryvault.1password.com 2>/dev/null) || true
                fi

                if [[ -n "$ts_key" ]]; then
                    sudo tailscale up --ssh --authkey="$ts_key" 2>/dev/null && echo "  [+] Tailscale up (SSH enabled)" || echo "  [!] tailscale up failed"
                elif tailscale status >/dev/null 2>&1; then
                    echo "  Already authenticated"
                    sudo tailscale set --ssh 2>/dev/null || true
                else
                    echo "  No auth key found. Run: sudo tailscale up --ssh"
                fi
            elif tailscale status >/dev/null 2>&1; then
                echo "  Already authenticated"
            else
                echo "  [!] sudo required. Run interactively: sudo tailscale up --ssh"
            fi
        else
            # Standard Tailscale app (GUI with sandboxed network extension)
            if ! brew list --cask tailscale &>/dev/null && ! ls /Applications/Tailscale.app &>/dev/null 2>&1; then
                echo "  Installing Tailscale app (cask)..."
                brew install --cask tailscale && echo "  [+] Tailscale app" || echo "  [!] Tailscale cask install failed"
            else
                echo "  Tailscale app already installed"
            fi
        fi
        return 0
    fi

    # --- Linux ---
    if command -v tailscale >/dev/null 2>&1; then
        echo "  Already installed"
    else
        echo "  Installing Tailscale..."
        curl -fsSL https://tailscale.com/install.sh | sh >/dev/null 2>&1 || { echo "  [!] Tailscale install failed"; return 0; }
        echo "  [+] Tailscale"
    fi

    # Start tailscaled if not running
    if ! pgrep -x tailscaled >/dev/null 2>&1; then
        if [ -d "/.sprite" ] && command -v sprite-env >/dev/null 2>&1; then
            # Sprite — register as a service so it survives sleep/wake
            sprite-env services create tailscaled --cmd /usr/sbin/tailscaled --args "--tun=userspace-networking" --no-stream 2>/dev/null || true
            sleep 2
        elif [ -d /run/systemd/system ]; then
            # systemd is the active init system (not just installed as a dep)
            $SUDO systemctl enable --now tailscaled 2>/dev/null || true
        else
            # No systemd, no Sprite (e.g. Apple Containers, exe.dev) — start directly
            $SUDO sh -c 'nohup tailscaled --tun=userspace-networking >/dev/null 2>&1 &'
            sleep 2
            # Add @reboot cron entry so tailscaled survives container/VM restarts
            local cron_cmd='@reboot nohup tailscaled --tun=userspace-networking >/dev/null 2>&1 &'
            if ! ($SUDO crontab -l 2>/dev/null | grep -qF 'tailscaled'); then
                ($SUDO crontab -l 2>/dev/null; echo "$cron_cmd") | $SUDO crontab -
            fi
        fi
    fi

    # Authenticate with --ssh if we have an auth key
    local ts_key="${TS_AUTHKEY:-}"

    if [[ -n "$ts_key" ]]; then
        local ts_hostname="${TS_HOSTNAME:-}"
        $SUDO tailscale up --ssh --authkey="$ts_key" ${ts_hostname:+--hostname "$ts_hostname"} 2>/dev/null && echo "  [+] Tailscale up (SSH enabled${ts_hostname:+, hostname=$ts_hostname})" || echo "  [!] tailscale up failed"
    elif tailscale status >/dev/null 2>&1; then
        echo "  Already authenticated"
        # Ensure SSH is enabled
        $SUDO tailscale set --ssh 2>/dev/null || true
    else
        echo "  No auth key found. Run: sudo tailscale up --ssh"
    fi
}

# --- install_apps ---
install_apps() {
    if [[ "$INSTALL_APPS" != true ]]; then
        return 0
    fi
    echo ""
    echo "=== Apps (brew bundle) ==="
    if [[ "$OS" != "macos" ]]; then
        echo "  Apps layer is macOS only, skipping."
        return 0
    fi
    brew bundle --file="$DOTFILES_DIR/homebrew/Brewfile" || echo "  Note: some casks/mas apps may have failed (normal)."

    # Sprite CLI
    if need sprite; then
        curl -fsSL https://sprites.dev/install.sh | sh >/dev/null 2>&1 && echo "  [+] Sprite CLI" || echo "  [!] Sprite CLI failed"
    fi

    # Archil.app (macOS menu bar app for distributed filesystem)
    if ! ls /Applications/Archil.app &>/dev/null; then
        curl -fsSL https://archil.com/install | sh || echo "  [!] Archil.app install failed"
    fi

    # Apple Container CLI — install or upgrade
    echo ""
    echo "=== Apple Container ==="
    local container_changed=false
    if command -v container >/dev/null 2>&1; then
        local installed_version latest_version release_json=""
        installed_version=$(container --version 2>/dev/null | awk '{print $4}' | tr -d ')')
        local gh_api_url="https://api.github.com/repos/apple/container/releases/latest"
        local -a curl_opts=(-fsSL)
        [[ -n "${GITHUB_TOKEN:-}" ]] && curl_opts+=(-H "Authorization: token $GITHUB_TOKEN")
        local attempt
        for attempt in 1 2; do
            release_json=$(curl "${curl_opts[@]}" "$gh_api_url" 2>/dev/null) && break
            [[ $attempt -eq 1 ]] && sleep $((RANDOM % 5 + 2))
        done
        if [[ -n "$release_json" ]]; then
            latest_version=$(echo "$release_json" | grep -oE '"tag_name": "[^"]+"' | head -1 | sed 's/"tag_name": "//;s/"//')
            if [[ "$installed_version" == "$latest_version" ]]; then
                echo "  Up to date ($installed_version)"
            else
                echo "  Upgrading $installed_version -> $latest_version"
                container system stop 2>/dev/null || true
                if [[ -x /usr/local/bin/update-container.sh ]]; then
                    sudo /usr/local/bin/update-container.sh && container_changed=true || echo "  [!] Upgrade failed"
                else
                    # Pre-0.10.0: no bundled update script, install pkg directly
                    local pkg_url="https://github.com/apple/container/releases/download/${latest_version}/container-${latest_version}-installer-signed.pkg"
                    if curl -fSL "$pkg_url" -o /tmp/container.pkg 2>/dev/null; then
                        sudo installer -pkg /tmp/container.pkg -target / && container_changed=true || echo "  [!] Upgrade failed"
                        rm -f /tmp/container.pkg
                    else
                        echo "  [!] Failed to download pkg"
                    fi
                fi
                container system start 2>/dev/null || true
            fi
        else
            echo "  [!] Failed to check for updates"
        fi
    else
        # Fresh install
        echo "  Installing..."
        local release_json="" latest_version=""
        local gh_api_url="https://api.github.com/repos/apple/container/releases/latest"
        local -a curl_opts=(-fsSL)
        [[ -n "${GITHUB_TOKEN:-}" ]] && curl_opts+=(-H "Authorization: token $GITHUB_TOKEN")
        local attempt
        for attempt in 1 2; do
            release_json=$(curl "${curl_opts[@]}" "$gh_api_url" 2>/dev/null) && break
            [[ $attempt -eq 1 ]] && sleep $((RANDOM % 5 + 2))
        done
        if [[ -n "$release_json" ]]; then
            latest_version=$(echo "$release_json" | grep -oE '"tag_name": "[^"]+"' | head -1 | sed 's/"tag_name": "//;s/"//')
            local pkg_url="https://github.com/apple/container/releases/download/${latest_version}/container-${latest_version}-installer-signed.pkg"
            if curl -fSL "$pkg_url" -o /tmp/container.pkg 2>/dev/null; then
                sudo installer -pkg /tmp/container.pkg -target / && container_changed=true || echo "  [!] Install failed"
                rm -f /tmp/container.pkg
            else
                echo "  [!] Failed to download pkg"
            fi
        else
            echo "  [!] Failed to fetch release info"
        fi
    fi
    if [[ "$container_changed" == true ]]; then
        echo "  [+] Apple Container $(container --version 2>/dev/null | awk '{print $4}' | tr -d ')')"
    fi

    # Load LaunchAgents
    if [[ "$DRY_RUN" != true ]]; then
        for plist in "$HOME/Library/LaunchAgents"/com.kylelundstedt.*.plist; do
            [[ -f "$plist" ]] && launchctl load -w "$plist" 2>/dev/null || true
        done
    fi
}

# --- Main ---
cd "$DOTFILES_DIR" || { echo "Error: $DOTFILES_DIR not found"; exit 1; }

echo "Install: OS=$OS, apps=$INSTALL_APPS, dry-run=$DRY_RUN"
echo ""

install_system_deps
install_cli_tools
install_python_clis
setup_node
setup_tailscale
setup_git
set_shell
run_stow
if [[ "$SKIP_AGENTS" != true ]]; then
    setup_agents
fi
install_apps

# Ensure Apple Container kernel is installed and system is running
if command -v container >/dev/null 2>&1; then
    echo ""
    echo "=== Apple Container System ==="
    container system kernel set --recommended 2>/dev/null && echo "  [+] Kernel set to recommended" || true
    container system start </dev/null 2>/dev/null || true
fi

echo ""
echo "Done. Start a new shell session (or run: exec zsh)"

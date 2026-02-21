#!/bin/bash
set -euo pipefail

# --- Args ---
INSTALL_APPS=false
DRY_RUN=false
NO_PROMPT=false
SKIP_STOW=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --apps)       INSTALL_APPS=true; shift ;;
        --dry-run)    DRY_RUN=true; shift ;;
        --no-prompt)  NO_PROMPT=true; shift ;;
        --skip-stow)  SKIP_STOW=true; shift ;;
        *)
            echo "Usage: $0 [--apps] [--dry-run] [--no-prompt] [--skip-stow]"
            exit 1
            ;;
    esac
done

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
[[ "$IS_INTERACTIVE" == false ]] && NO_PROMPT=true

DOTFILES_DIR="$HOME/dotfiles"
LOCAL_BIN="$HOME/.local/bin"
mkdir -p "$LOCAL_BIN"
export PATH="$LOCAL_BIN:$PATH"

# --- Helpers ---
need() { ! command -v "$1" >/dev/null 2>&1; }

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

    if curl -fsSL "$asset_url" -o "$tmp/$asset_name"; then
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
        sudo apt-get update -qq 2>/dev/null || true
        sudo apt-get install -y -qq stow zsh git curl unzip
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

    # All installs run in parallel — each writes to a unique binary/path
    local pids=()

    # Curl install scripts
    if need starship; then
        (curl -fsSL https://starship.rs/install.sh | sh -s -- --yes --bin-dir="$LOCAL_BIN" >/dev/null 2>&1 && echo "  [+] starship" || echo "  [!] starship failed") &
        pids+=($!)
    fi
    if need uv; then
        (curl -fsSL https://astral.sh/uv/install.sh | env CARGO_HOME="$HOME/.local" sh >/dev/null 2>&1 && echo "  [+] uv" || echo "  [!] uv failed") &
        pids+=($!)
    fi
    if need atuin; then
        (curl -fsSL https://setup.atuin.sh | sh -s -- --yes --no-modify-path >/dev/null 2>&1 && echo "  [+] atuin" || echo "  [!] atuin failed") &
        pids+=($!)
    fi
    if need zoxide; then
        (curl -fsSL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | sh >/dev/null 2>&1 && echo "  [+] zoxide" || echo "  [!] zoxide failed") &
        pids+=($!)
    fi
    if need direnv; then
        (curl -fsSL https://direnv.net/install.sh | bash >/dev/null 2>&1 && echo "  [+] direnv" || echo "  [!] direnv failed") &
        pids+=($!)
    fi
    if need just; then
        (curl -fsSL https://just.systems/install.sh | bash -s -- --to "$LOCAL_BIN" >/dev/null 2>&1 && echo "  [+] just" || echo "  [!] just failed") &
        pids+=($!)
    fi
    if need fnm; then
        (curl -fsSL https://fnm.vercel.app/install | bash -s -- --skip-shell --install-dir "$LOCAL_BIN" >/dev/null 2>&1 && echo "  [+] fnm" || echo "  [!] fnm failed") &
        pids+=($!)
    fi

    # GitHub release binaries
    # bat/ripgrep use Rust target triples; gh/duckdb/others use Go-style os_arch
    if need bat; then
        (install_github_binary "sharkdp/bat" "bat-v.*-${target_triple}.*\\.tar\\.gz" "bat" "") &
        pids+=($!)
    fi
    if need fzf; then
        (install_github_binary "junegunn/fzf" "fzf-.*-${gh_os}_${gh_arch}\\.tar\\.gz" "fzf" "fzf") &
        pids+=($!)
    fi
    if need rg; then
        (install_github_binary "BurntSushi/ripgrep" "ripgrep-.*-${target_triple}.*\\.tar\\.gz" "rg" "") &
        pids+=($!)
    fi
    if need jq; then
        (install_github_binary "jqlang/jq" "jq-${gh_os}-${gh_arch}\"$" "jq" "jq-${gh_os}-${gh_arch}") &
        pids+=($!)
    fi
    if need yq; then
        (install_github_binary "mikefarah/yq" "yq_${gh_os}_${gh_arch}\"$" "yq" "yq_${gh_os}_${gh_arch}") &
        pids+=($!)
    fi
    if need gh; then
        (install_github_binary "cli/cli" "gh_.*_${gh_cli_os}_${gh_arch}\\.(tar\\.gz|zip)" "gh" "") &
        pids+=($!)
    fi
    if need duckdb; then
        (install_github_binary "duckdb/duckdb" "duckdb_cli-${duckdb_os}-${gh_arch}\\.zip" "duckdb" "duckdb") &
        pids+=($!)
    fi
    if need carapace; then
        (install_github_binary "carapace-sh/carapace-bin" "carapace-bin_.*_${gh_os}_${gh_arch}\\.tar\\.gz" "carapace" "carapace") &
        pids+=($!)
    fi

    # Wait for all parallel installs
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
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

    # SSH multiplexing for GitHub
    local ssh_config="$HOME/.ssh/config"
    if [[ -f "$ssh_config" ]] && ! grep -q 'Host github.com' "$ssh_config"; then
        mkdir -p "$HOME/.ssh/sockets"
        cat >> "$ssh_config" <<'SSHEOF'

Host github.com
  ControlMaster auto
  ControlPath ~/.ssh/sockets/%r@%h-%p
  ControlPersist 600
SSHEOF
        echo "  [+] SSH multiplexing for github.com"
    fi

    # Ensure local config exists
    touch "$git_config_local"
    if [[ -s "$git_config_local" ]]; then
        echo "  Git user config already set"
        return 0
    fi

    # Prompt for name/email
    if [[ "$IS_INTERACTIVE" == true ]]; then
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
    else
        echo "  Skipping git user setup (non-interactive). Run install.sh interactively to configure."
    fi
}

# --- set_shell ---
set_shell() {
    local desired_shell
    desired_shell="$(command -v zsh || true)"
    if [[ -n "$desired_shell" && "$SHELL" != "$desired_shell" ]]; then
        chsh -s "$desired_shell" 2>/dev/null || echo "  Note: could not change shell to zsh"
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
        packages+=("aws")
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
        if [[ "$NO_PROMPT" != true ]]; then
            read -rp "  Stow '$folder'? [y/N]: " reply
            [[ "$reply" != [yY] ]] && continue
        fi
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

    # Claude Code CLI
    if need claude && [[ ! -f "$LOCAL_BIN/claude" ]]; then
        echo "  Installing Claude Code CLI..."
        if curl -fsSL https://claude.ai/install.sh | bash >/dev/null 2>&1; then
            echo "  [+] Claude Code"
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
        curl -sS https://downloads.1password.com/linux/keys/1password.asc | sudo gpg --dearmor --output /usr/share/keyrings/1password-archive-keyring.gpg 2>/dev/null || true
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/1password-archive-keyring.gpg] https://downloads.1password.com/linux/debian/$(dpkg --print-architecture) stable main" | sudo tee /etc/apt/sources.list.d/1password.list >/dev/null 2>&1 || true
        sudo apt-get update -qq >/dev/null 2>&1 && sudo apt-get install -y -qq 1password-cli >/dev/null 2>&1 && echo "  [+] 1Password CLI" || echo "  [!] 1Password CLI failed"
    fi

    # MCP servers (shared wrapper paths)
    echo "  Configuring MCP servers..."
    local mcp_wrappers=(
        "github-home:$DOTFILES_DIR/agents/.agents/mcp/bin/github-mcp-home"
        "github-work:$DOTFILES_DIR/agents/.agents/mcp/bin/github-mcp-work"
        "motherduck:$DOTFILES_DIR/agents/.agents/mcp/bin/motherduck-mcp"
        "dlt:$DOTFILES_DIR/agents/.agents/mcp/bin/dlt-mcp"
        "tigris:$DOTFILES_DIR/agents/.agents/mcp/bin/tigris-mcp"
    )
    for tool in claude codex; do
        command -v "$tool" >/dev/null 2>&1 || continue
        for spec in "${mcp_wrappers[@]}"; do
            local name="${spec%%:*}" wrapper="${spec#*:}"
            [[ ! -x "$wrapper" ]] && continue
            local cmd
            if [[ "$tool" == "claude" ]]; then
                cmd=("$tool" mcp add --scope user "$name" -- "$wrapper")
            else
                cmd=("$tool" mcp add "$name" -- "$wrapper")
            fi
            "${cmd[@]}" 2>/dev/null || true
        done

        # Codex startup timeout patch
        if [[ "$tool" == "codex" ]]; then
            local codex_config="$HOME/.codex/config.toml"
            if [[ -f "$codex_config" ]] && command -v python3 >/dev/null 2>&1; then
                python3 -c '
import sys, re
p = sys.argv[1]
t = open(p).read()
parts = re.split(r"(?=\[mcp_servers\.)", t)
result = []
for s in parts:
    if s.startswith("[mcp_servers.") and "startup_timeout_sec" not in s:
        s = re.sub(r"(command = [^\n]+\n)", r"\1startup_timeout_sec = 30\n", s)
    result.append(s)
open(p, "w").write("".join(result))
' "$codex_config"
            fi
        fi
    done
    echo "  [+] MCP servers configured"

    # Skills
    if command -v npx >/dev/null 2>&1; then
        echo "  Installing agent skills..."
        npx -y skills add -g -y matsonj/mviz 2>/dev/null || true
        npx -y skills add -g -y vercel-labs/skills -s find-skills 2>/dev/null || true
        npx -y skills add -g -y kylelundstedt/dotfiles -s bootstrap-project data-pipelines sprites 2>/dev/null || true
        echo "  [+] Skills installed"
    else
        echo "  [!] npx not found, skipping skill installation"
    fi

    if ! command -v op >/dev/null 2>&1; then
        echo ""
        echo "  Note: 1Password CLI is required at runtime for secret-backed MCP servers."
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
setup_node
setup_git
set_shell
run_stow
setup_agents
install_apps

echo ""
echo "Done. Start a new shell session (or run: exec zsh)"

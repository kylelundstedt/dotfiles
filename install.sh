#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# Ensure USER is set (not always present in minimal containers)
USER="${USER:-$(whoami)}"

SUDO_PID=""
STOW_DRY_RUN=false
STOW_NO_PROMPT=false
INCLUDE_HEAVY=false
SKIP_STOW=false
FORCE_INTERACTIVE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            STOW_DRY_RUN=true
            shift
            ;;
        --no-prompt)
            STOW_NO_PROMPT=true
            shift
            ;;
        --include-heavy)
            INCLUDE_HEAVY=true
            shift
            ;;
        --skip-stow)
            SKIP_STOW=true
            shift
            ;;
        --interactive)
            FORCE_INTERACTIVE=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--dry-run] [--no-prompt] [--include-heavy] [--skip-stow] [--interactive]"
            exit 1
            ;;
    esac
done

# Detect the operating system
if [[ "$OSTYPE" == "darwin"* ]]; then
    OS="macos"
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    OS="linux"
else
    echo "Unsupported operating system"
    exit 1
fi

IS_INTERACTIVE=false
if [[ -t 0 && -t 1 ]]; then
    IS_INTERACTIVE=true
fi
if [[ "$FORCE_INTERACTIVE" == true ]]; then
    IS_INTERACTIVE=true
fi

if [[ "$IS_INTERACTIVE" == false ]]; then
    STOW_NO_PROMPT=true
fi

append_line_if_missing() {
    file="$1"
    line="$2"
    if [ -f "$file" ]; then
        if ! grep -Fq "$line" "$file"; then
            echo "$line" >> "$file"
        fi
    else
        echo "$line" > "$file"
    fi
}

backup_if_regular_file() {
    local path backup_path
    path="$1"
    if [[ -f "$path" && ! -L "$path" ]]; then
        backup_path="${path}.pre-dotfiles.$(date +%Y%m%d%H%M%S)"
        mv "$path" "$backup_path"
        echo "Backed up $path to $backup_path"
    fi
}

configure_git_os_include() {
    local include_path target_file
    target_file="$HOME/.gitconfig_os_local"
    case "$OS" in
        macos)
            include_path="~/.gitconfig_macos"
            ;;
        linux)
            include_path="~/.gitconfig_linux"
            ;;
        *)
            return 0
            ;;
    esac

    cat > "$target_file" <<EOF
[include]
    path = $include_path
EOF
}

prompt_git_user() {
    local git_name git_email
    echo ""
    echo "Git Configuration Setup"
    echo "Please provide your Git user information:"
    echo ""
    echo "Examples:"
    echo "  Name:  John Doe"
    echo "  Email: john.doe@example.com"
    echo ""

    if [ -t 0 ]; then
        read -rp "Git user name: " git_name
        if [[ -z "$git_name" ]]; then
            echo "Error: Git user name is required"
            exit 1
        fi
        read -rp "Git email: " git_email
        if [[ -z "$git_email" ]]; then
            echo "Error: Git email is required"
            exit 1
        fi
    else
        local existing_name existing_email
        existing_name=$(git config --global user.name 2>/dev/null || echo "")
        existing_email=$(git config --global user.email 2>/dev/null || echo "")
        if [[ -n "$existing_name" ]] && [[ -n "$existing_email" ]]; then
            echo "Using existing Git configuration from system..."
            git_name="$existing_name"
            git_email="$existing_email"
        else
            echo ""
            echo "Skipping Git user configuration (non-interactive mode)."
            echo "Run later: cd ~/dotfiles && ./install.sh"
            echo ""
            return 0
        fi
    fi

    if [[ -n "$git_name" ]] && [[ -n "$git_email" ]]; then
        cat > "$GIT_CONFIG_LOCAL" <<EOF
[user]
name = $git_name
email = $git_email
EOF
        echo "Created Git local configuration (gitignored)"
    fi
}

install_apt_packages_quiet() {
    if [ "$#" -eq 0 ]; then
        return 0
    fi
    if ! DEBIAN_FRONTEND=noninteractive run_privileged apt-get -qq install -y "$@" >/tmp/apt-install.log 2>&1; then
        cat /tmp/apt-install.log
        return 1
    fi
}

configure_claude() {
    configure_mcp_servers
    install_skills
}

configure_mcp_servers() {
    local mcp_failed=false

    # Shared MCP wrapper paths (agent-agnostic, stow-managed under agents/.agents/mcp/bin).
    local mcp_specs=(
        "github-home:$HOME/dotfiles/agents/.agents/mcp/bin/github-mcp-home"
        "github-work:$HOME/dotfiles/agents/.agents/mcp/bin/github-mcp-work"
        "motherduck:$HOME/dotfiles/agents/.agents/mcp/bin/motherduck-mcp"
        "dlt:$HOME/dotfiles/agents/.agents/mcp/bin/dlt-mcp"
        "tigris:$HOME/dotfiles/agents/.agents/mcp/bin/tigris-mcp"
    )

    configure_mcp_servers_for_tool "claude" "${mcp_specs[@]}" || mcp_failed=true
    configure_mcp_servers_for_tool "codex" "${mcp_specs[@]}" || mcp_failed=true

    if [[ "$mcp_failed" == true ]]; then
        echo "  [!] One or more MCP server registrations failed"
    fi

    if ! command -v op >/dev/null 2>&1; then
        echo ""
        echo "  Note: 1Password CLI is required at runtime for secret-backed MCP servers."
        echo "        Install it first, then re-run install.sh."
    fi
}

configure_mcp_servers_for_tool() {
    local tool add_cmd failed=false
    tool="$1"
    shift

    if ! command -v "$tool" >/dev/null 2>&1; then
        return 0
    fi

    echo "Configuring $tool MCP servers..."

    for spec in "$@"; do
        local server_name wrapper_path add_output
        server_name="${spec%%:*}"
        wrapper_path="${spec#*:}"

        if [[ ! -x "$wrapper_path" ]]; then
            echo "Warning: MCP wrapper missing or not executable: $wrapper_path" >&2
            failed=true
            continue
        fi

        if [[ "$tool" == "claude" ]]; then
            add_cmd=("$tool" "mcp" "add" "--scope" "user" "$server_name" "--" "$wrapper_path")
        else
            add_cmd=("$tool" "mcp" "add" "$server_name" "--" "$wrapper_path")
        fi

        if ! add_output=$("${add_cmd[@]}" 2>&1); then
            if echo "$add_output" | grep -Eqi "already exists|already configured"; then
                continue
            fi
            echo "Warning: failed to configure MCP server '$server_name' for $tool" >&2
            [ -n "$add_output" ] && echo "$add_output" >&2
            failed=true
        fi
    done

    if [[ "$failed" == false ]]; then
        echo "  [+] MCP servers configured for $tool"
        return 0
    fi

    return 1
}

# Run a command with elevated privileges (sudo if available, direct if root)
run_privileged() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        # Pass DEBIAN_FRONTEND through sudo (sudo strips env vars by default)
        if [ -n "${DEBIAN_FRONTEND:-}" ]; then
            sudo DEBIAN_FRONTEND="$DEBIAN_FRONTEND" "$@"
        else
            sudo "$@"
        fi
    else
        echo "Error: requires root or sudo"
        return 1
    fi
}

filter_apt_packages() {
    for pkg in "$@"; do
        # Check if package exists in apt cache
        # Using variable capture avoids pipe issues in subshell context
        local output
        output=$(apt-cache show "$pkg" 2>/dev/null) || true
        if [[ -n "$output" ]]; then
            printf '%s\n' "$pkg"
        else
            echo "Skipping missing apt package: $pkg" >&2
        fi
    done
}

sudo_ok() {
    if command -v sudo >/dev/null 2>&1; then
        sudo -n true >/dev/null 2>&1
        return $?
    fi
    return 1
}

core_tools_installed() {
    # Check for key tools; bat may be batcat on Debian/Ubuntu
    command -v fzf >/dev/null 2>&1 || return 1
    command -v rg >/dev/null 2>&1 || return 1
    command -v zoxide >/dev/null 2>&1 || return 1
    command -v starship >/dev/null 2>&1 || return 1
    command -v stow >/dev/null 2>&1 || return 1
    { command -v bat >/dev/null 2>&1 || command -v batcat >/dev/null 2>&1; } || return 1
    return 0
}

cleanup_sudo_keepalive() {
    if [[ -n "${SUDO_PID:-}" ]] && kill -0 "$SUDO_PID" 2>/dev/null; then
        kill "$SUDO_PID" 2>/dev/null || true
    fi
}

link_skill() {
    local name="$1"
    local target="../../.agents/skills/$name"
    [ ! -L "$HOME/.claude/skills/$name" ] && ln -sf "$target" "$HOME/.claude/skills/$name"
    [ ! -L "$HOME/.codex/skills/$name" ] && ln -sf "$target" "$HOME/.codex/skills/$name"
}

install_skills() {
    echo "Installing agent skills..."
    mkdir -p "$HOME/.agents/skills" "$HOME/.claude/skills" "$HOME/.codex/skills"

    # mviz - chart & report builder (matsonj/mviz)
    if [ ! -d "$HOME/.agents/skills/mviz" ]; then
        if GIT_TERMINAL_PROMPT=0 git clone --quiet --depth=1 https://github.com/matsonj/mviz.git "$HOME/.agents/skills/mviz" 2>/dev/null; then
            echo "  [+] mviz skill installed"
        else
            echo "  [!] mviz skill installation failed"
        fi
    fi
    link_skill mviz

    # find-skills - skill discovery (vercel-labs/skills, subdirectory)
    if [ ! -d "$HOME/.agents/skills/find-skills" ]; then
        SKILLS_TMP=$(mktemp -d)
        if GIT_TERMINAL_PROMPT=0 git clone --quiet --depth=1 https://github.com/vercel-labs/skills.git "$SKILLS_TMP" 2>/dev/null; then
            mv "$SKILLS_TMP/skills/find-skills" "$HOME/.agents/skills/find-skills"
            echo "  [+] find-skills skill installed"
        else
            echo "  [!] find-skills skill installation failed"
        fi
        rm -rf "$SKILLS_TMP"
    fi
    link_skill find-skills

    # bootstrap-project - link if already deployed by stow
    if [ -d "$HOME/.agents/skills/bootstrap-project" ]; then
        link_skill bootstrap-project
    fi
}

trap cleanup_sudo_keepalive EXIT

# Summary
echo "Install summary:"
echo "  OS: $OS"
echo "  Interactive: $IS_INTERACTIVE"
echo "  Stow dry-run: $STOW_DRY_RUN"
echo "  Stow no-prompt: $STOW_NO_PROMPT"
echo "  Include heavy (casks/MAS): $INCLUDE_HEAVY"
echo "  Skip stow: $SKIP_STOW"
echo ""

# Ensure required tools for setup are available
if ! command -v git >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
    if [[ "$OS" == "linux" ]]; then
        echo "Installing missing prerequisites (git/curl/sudo/zsh)..."
        RUN_AS_ROOT=false
        if [ "$(id -u)" -eq 0 ]; then
            RUN_AS_ROOT=true
        fi
        if [[ "$IS_INTERACTIVE" == false ]] && [[ "$RUN_AS_ROOT" == false ]] && ! sudo_ok; then
            echo "Error: sudo requires a password in non-interactive mode."
            echo "Run as root or re-run with --interactive."
            exit 1
        fi

        if command -v apt-get >/dev/null 2>&1; then
            # Single apt-get update for prerequisites
            DEBIAN_FRONTEND=noninteractive run_privileged apt-get -qq update >/tmp/apt-update.log 2>&1 || true
            if command -v sudo >/dev/null 2>&1; then
                install_apt_packages_quiet git curl sudo zsh
            elif [[ "$RUN_AS_ROOT" == true ]]; then
                DEBIAN_FRONTEND=noninteractive apt-get -qq update >/tmp/apt-update.log 2>&1 || {
                    cat /tmp/apt-update.log
                    exit 1
                }
                DEBIAN_FRONTEND=noninteractive apt-get -qq install -y git curl sudo zsh >/tmp/apt-install.log 2>&1 || {
                    cat /tmp/apt-install.log
                    exit 1
                }
            else
                echo "Error: sudo is not installed and you are not root."
                echo "Please install sudo or run this script as root."
                exit 1
            fi
        elif command -v dnf >/dev/null 2>&1; then
            if command -v sudo >/dev/null 2>&1; then
                sudo dnf -q install -y git curl sudo zsh
            elif [[ "$RUN_AS_ROOT" == true ]]; then
                dnf -q install -y git curl sudo zsh
            else
                echo "Error: sudo is not installed and you are not root."
                echo "Please install sudo or run this script as root."
                exit 1
            fi
        elif command -v yum >/dev/null 2>&1; then
            if command -v sudo >/dev/null 2>&1; then
                sudo yum -q install -y git curl sudo zsh
            elif [[ "$RUN_AS_ROOT" == true ]]; then
                yum -q install -y git curl sudo zsh
            else
                echo "Error: sudo is not installed and you are not root."
                echo "Please install sudo or run this script as root."
                exit 1
            fi
        elif command -v pacman >/dev/null 2>&1; then
            if command -v sudo >/dev/null 2>&1; then
                sudo pacman -Sy --noconfirm --quiet git curl sudo zsh
            elif [[ "$RUN_AS_ROOT" == true ]]; then
                pacman -Sy --noconfirm --quiet git curl sudo zsh
            else
                echo "Error: sudo is not installed and you are not root."
                echo "Please install sudo or run this script as root."
                exit 1
            fi
        elif command -v zypper >/dev/null 2>&1; then
            if command -v sudo >/dev/null 2>&1; then
                sudo zypper -q install -y git curl sudo zsh
            elif [[ "$RUN_AS_ROOT" == true ]]; then
                zypper -q install -y git curl sudo zsh
            else
                echo "Error: sudo is not installed and you are not root."
                echo "Please install sudo or run this script as root."
                exit 1
            fi
        else
            echo "Error: git and curl are required but no supported package manager was found."
            exit 1
        fi
    fi
fi

if ! command -v git >/dev/null 2>&1; then
    echo "Error: git is required but not installed."
    echo "Please install git and re-run this script."
    exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
    echo "Error: curl is required but not installed."
    echo "Please install curl and re-run this script."
    exit 1
fi

# Bootstrap from canonical repo to avoid cached installer scripts.
# If we're not running from ~/dotfiles/install.sh, fetch/update the repo and exec it.
SCRIPT_SOURCE="${BASH_SOURCE[0]:-$0}"
if [[ "${DOTFILES_BOOTSTRAP:-0}" != "1" && "$SCRIPT_SOURCE" != "$HOME/dotfiles/install.sh" ]]; then
    export DOTFILES_BOOTSTRAP=1
    DOTFILES_DIR="$HOME/dotfiles"
    if [ -d "$DOTFILES_DIR/.git" ]; then
        git -C "$DOTFILES_DIR" fetch --quiet origin || true
        if [[ -z "$(git -C "$DOTFILES_DIR" status --porcelain 2>/dev/null || true)" ]]; then
            git -C "$DOTFILES_DIR" pull --ff-only --quiet || true
        else
            echo "Skipping dotfiles auto-update in $DOTFILES_DIR (local changes detected)."
        fi
    else
        mkdir -p "$DOTFILES_DIR"
        GIT_TERMINAL_PROMPT=0 git clone --quiet --depth=1 --filter=blob:none https://github.com/kylelundstedt/dotfiles "$DOTFILES_DIR"
    fi
    if [ -f "$DOTFILES_DIR/install.sh" ]; then
        exec bash "$DOTFILES_DIR/install.sh" "$@"
    fi
fi

# Set default shell from actual installed zsh path
DESIRED_SHELL="$(command -v zsh || true)"
if [[ -z "$DESIRED_SHELL" ]]; then
    if [[ "$OSTYPE" == "darwin"* ]]; then
        DESIRED_SHELL="/bin/zsh"
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        DESIRED_SHELL="/usr/bin/zsh"
    fi
fi

set_shell() {
    if [[ -n "$DESIRED_SHELL" ]] && command -v zsh >/dev/null 2>&1; then
        if [[ "$SHELL" != "$DESIRED_SHELL" ]]; then
            if [[ "$IS_INTERACTIVE" == true ]]; then
                chsh -s "$DESIRED_SHELL" "$USER" || echo "Warning: unable to change shell to $DESIRED_SHELL"
            elif [ "$(id -u)" -eq 0 ]; then
                # Running as root - use chsh or usermod directly
                if command -v chsh >/dev/null 2>&1; then
                    chsh -s "$DESIRED_SHELL" "$USER" || echo "Warning: unable to change shell to $DESIRED_SHELL"
                elif command -v usermod >/dev/null 2>&1; then
                    usermod -s "$DESIRED_SHELL" "$USER" || echo "Warning: unable to change shell to $DESIRED_SHELL"
                fi
            elif sudo_ok; then
                sudo -n chsh -s "$DESIRED_SHELL" "$USER" || echo "Warning: unable to change shell to $DESIRED_SHELL"
            else
                echo "Non-interactive mode: unable to change shell (no sudo/root)."
            fi
        fi
    fi
}

set_shell

# Install zsh on Linux if missing (needed for setup)
if [[ "$OS" == "linux" ]] && ! command -v zsh >/dev/null 2>&1; then
    echo "Installing zsh (required for setup)..."
    if command -v apt-get >/dev/null 2>&1; then
        run_privileged apt-get update && run_privileged apt-get install -y zsh
    elif command -v dnf >/dev/null 2>&1; then
        run_privileged dnf install -y zsh
    elif command -v yum >/dev/null 2>&1; then
        run_privileged yum install -y zsh
    elif command -v pacman >/dev/null 2>&1; then
        run_privileged pacman -Sy --noconfirm zsh
    elif command -v zypper >/dev/null 2>&1; then
        run_privileged zypper install -y zsh
    fi
fi

# Define the path for the dotfiles directory
DOTFILES_DIR="$HOME/dotfiles"

# Check if the dotfiles directory already exists
if [ -d "$DOTFILES_DIR" ]; then
    echo "The dotfiles directory already exists: $DOTFILES_DIR"
else
    # Create the dotfiles directory
    mkdir -p "$DOTFILES_DIR"
    echo "Created dotfiles directory: $DOTFILES_DIR"
    GIT_TERMINAL_PROMPT=0 git clone --quiet --depth=1 --filter=blob:none https://github.com/kylelundstedt/dotfiles "$DOTFILES_DIR"
fi

# Define folder lists
linux_folders=("aws" "agents" "claude" "git" "starship" "zsh")
# include git, zsh, starship on mac so prompt and git config are applied
macos_folders=("1Password" "agents" "claude" "vscode" "homebrew" "ssh" "git" "zsh" "starship")

# Change to the dotfiles directory
cd "$HOME/dotfiles" || exit

# Make sure main git config includes exactly one OS-specific file.
configure_git_os_include

# Ensure install.sh is executable
if [ -f "$HOME/dotfiles/install.sh" ] && [ ! -x "$HOME/dotfiles/install.sh" ]; then
    chmod +x "$HOME/dotfiles/install.sh"
fi

# Prompt for Git user configuration and save to gitignored local file
GIT_CONFIG_LOCAL="$HOME/dotfiles/git/.gitconfig_local"
GIT_CONFIG_COMMON="$HOME/dotfiles/git/.gitconfig_common"

# Ensure local config file exists (even if empty) to avoid Git include errors
if [ ! -f "$GIT_CONFIG_LOCAL" ]; then
    touch "$GIT_CONFIG_LOCAL"
fi

# Check if local config already has values
if [ -f "$GIT_CONFIG_LOCAL" ] && [ -s "$GIT_CONFIG_LOCAL" ]; then
    CURRENT_NAME=$(grep -E "^name = " "$GIT_CONFIG_LOCAL" | cut -d'=' -f2 | xargs)
    CURRENT_EMAIL=$(grep -E "^email = " "$GIT_CONFIG_LOCAL" | cut -d'=' -f2 | xargs)
    if [[ -n "$CURRENT_NAME" ]] && [[ -n "$CURRENT_EMAIL" ]]; then
        echo "Git configuration already set (name: $CURRENT_NAME, email: $CURRENT_EMAIL)"
    fi
else
    # Check if .gitconfig_common has real values (not template) — migrate them
    if [ -f "$GIT_CONFIG_COMMON" ]; then
        COMMON_NAME=$(grep -E "^name = " "$GIT_CONFIG_COMMON" | cut -d'=' -f2 | xargs)
        COMMON_EMAIL=$(grep -E "^email = " "$GIT_CONFIG_COMMON" | cut -d'=' -f2 | xargs)

        if [[ "$COMMON_NAME" != "Your Name" ]] && [[ "$COMMON_EMAIL" != "your.email@example.com" ]] && [[ -n "$COMMON_NAME" ]] && [[ -n "$COMMON_EMAIL" ]]; then
            echo "Migrating Git config from .gitconfig_common to .gitconfig_local (gitignored)..."
            cat > "$GIT_CONFIG_LOCAL" <<EOF
[user]
name = $COMMON_NAME
email = $COMMON_EMAIL
EOF
            # Restore template values in common file (BSD sed fallback for macOS)
            sed -i.bak "s/^name = .*/name = Your Name/" "$GIT_CONFIG_COMMON" && rm -f "$GIT_CONFIG_COMMON.bak"
            sed -i.bak "s/^email = .*/email = your.email@example.com/" "$GIT_CONFIG_COMMON" && rm -f "$GIT_CONFIG_COMMON.bak"
            echo "Migrated Git configuration to local file (gitignored)"
        else
            prompt_git_user
        fi
    else
        prompt_git_user
    fi
    echo ""
fi

# Install core Linux tools via apt when available
NEED_BREW=false
CORE_INSTALLED=false
if [[ "$OS" == "linux" ]]; then
    if core_tools_installed; then
        echo "Core tools already installed, skipping package installation."
        CORE_INSTALLED=true
        NEED_BREW=false
    elif command -v apt-get >/dev/null 2>&1; then
        echo "Installing core CLI tools via apt..."
        # Update apt cache first so filter_apt_packages can check availability
        DEBIAN_FRONTEND=noninteractive run_privileged apt-get -qq update >/dev/null 2>&1 || true
        # Aligned with Brewfile.linux (excluding tools not in apt repos)
        # Note: nodejs/npm excluded - installed via NodeSource for smaller footprint
        CORE_APT_PACKAGES=(
            atuin
            awscli
            bat
            curl
            direnv
            fastfetch
            fzf
            gh
            git
            gnupg
            htop
            jq
            just
            micro
            nano
            pandoc
            parallel
            rclone
            ripgrep
            stow
            tree
            wget
            yq
            zoxide
        )
        mapfile -t CORE_APT_PACKAGES_FILTERED < <(filter_apt_packages "${CORE_APT_PACKAGES[@]}")
        APT_PID=""
        if [ "${#CORE_APT_PACKAGES_FILTERED[@]}" -gt 0 ]; then
            # Run apt-get install in background so we can overlap with network downloads
            (
                if ! DEBIAN_FRONTEND=noninteractive run_privileged apt-get -qq install -y "${CORE_APT_PACKAGES_FILTERED[@]}" >/tmp/apt-install.log 2>&1; then
                    cat /tmp/apt-install.log >&2
                    exit 1
                fi
            ) &
            APT_PID=$!
        fi

        # Install starship, carapace, and uv in parallel (overlapping with apt-get)
        echo "Installing apt packages + starship, carapace, uv in parallel..."

        # Starship installation (background)
        if ! command -v starship >/dev/null 2>&1; then
            (
                if [ "$(id -u)" -eq 0 ]; then
                    curl -sS https://starship.rs/install.sh | sh -s -- --yes >/dev/null 2>&1 && echo "  [+] starship installed" || echo "  [!] starship failed"
                elif sudo -n true 2>/dev/null; then
                    curl -sS https://starship.rs/install.sh | sudo sh -s -- --yes >/dev/null 2>&1 && echo "  [+] starship installed" || echo "  [!] starship failed"
                else
                    curl -sS https://starship.rs/install.sh | sh -s -- --yes --bin-dir="$HOME/.local/bin" >/dev/null 2>&1 && echo "  [+] starship installed" || echo "  [!] starship failed"
                fi
            ) &
            STARSHIP_PID=$!
        fi

        # Carapace installation (background)
        if ! command -v carapace >/dev/null 2>&1; then
            (
                CARAPACE_TMP=$(mktemp -d)
                CARAPACE_ARCH="amd64"
                [ "$(uname -m)" = "aarch64" ] && CARAPACE_ARCH="arm64"
                # Get latest version tag from GitHub API
                CARAPACE_VERSION=$(curl -sL "https://api.github.com/repos/carapace-sh/carapace-bin/releases/latest" | grep '"tag_name"' | sed -E 's/.*"v([^"]+)".*/\1/')
                if [ -n "$CARAPACE_VERSION" ] && curl -sL "https://github.com/carapace-sh/carapace-bin/releases/download/v${CARAPACE_VERSION}/carapace-bin_${CARAPACE_VERSION}_linux_${CARAPACE_ARCH}.tar.gz" | tar -xz -C "$CARAPACE_TMP" 2>/dev/null; then
                    if [ "$(id -u)" -eq 0 ]; then
                        mv "$CARAPACE_TMP/carapace" /usr/local/bin/carapace && chmod +x /usr/local/bin/carapace
                    elif sudo -n true 2>/dev/null; then
                        sudo mv "$CARAPACE_TMP/carapace" /usr/local/bin/carapace && sudo chmod +x /usr/local/bin/carapace
                    else
                        mkdir -p "$HOME/.local/bin"
                        mv "$CARAPACE_TMP/carapace" "$HOME/.local/bin/carapace" && chmod +x "$HOME/.local/bin/carapace"
                    fi
                    echo "  [+] carapace installed"
                else
                    echo "  [!] carapace failed"
                fi
                rm -rf "$CARAPACE_TMP"
            ) &
            CARAPACE_PID=$!
        fi

        # UV installation (background)
        if ! command -v uv >/dev/null 2>&1; then
            (
                curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null 2>&1 && echo "  [+] uv installed" || echo "  [!] uv failed"
            ) &
            UV_PID=$!
        fi

        # Wait for all parallel installations to complete
        [ -n "${STARSHIP_PID:-}" ] && wait "$STARSHIP_PID" 2>/dev/null
        [ -n "${CARAPACE_PID:-}" ] && wait "$CARAPACE_PID" 2>/dev/null
        [ -n "${UV_PID:-}" ] && wait "$UV_PID" 2>/dev/null

        # Wait for apt-get to complete (needed for 1Password which uses apt)
        if [ -n "$APT_PID" ]; then
            if ! wait "$APT_PID"; then
                echo "Error: apt-get install failed"
                exit 1
            fi
            echo "  [+] apt packages installed"
        fi

        # Add uv to PATH for this session (after it's installed)
        export PATH="$HOME/.local/bin:$PATH"

        # Install 1Password CLI (required for MCP servers to fetch GitHub PATs)
        if ! command -v op >/dev/null 2>&1; then
            echo "Installing 1Password CLI..."
            # Add 1Password GPG key and repository
            curl -sS https://downloads.1password.com/linux/keys/1password.asc | run_privileged gpg --dearmor --output /usr/share/keyrings/1password-archive-keyring.gpg 2>/dev/null || true
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/1password-archive-keyring.gpg] https://downloads.1password.com/linux/debian/$(dpkg --print-architecture) stable main" | run_privileged tee /etc/apt/sources.list.d/1password.list >/dev/null 2>&1 || true
            # Install 1password-cli
            if DEBIAN_FRONTEND=noninteractive run_privileged apt-get -qq update >/dev/null 2>&1 && \
               DEBIAN_FRONTEND=noninteractive run_privileged apt-get -qq install -y 1password-cli >/dev/null 2>&1; then
                echo "  [+] 1Password CLI installed"
            else
                echo "Warning: 1Password CLI installation failed. You can install it manually later:"
                echo "  https://developer.1password.com/docs/cli/get-started/"
            fi
        fi

        # Install Claude Code CLI via native installer (no Node.js required)
        if ! command -v claude >/dev/null 2>&1 && [ ! -f "$HOME/.local/bin/claude" ]; then
            echo "Installing Claude Code CLI..."
            if curl -fsSL https://claude.ai/install.sh | bash >/dev/null 2>&1; then
                echo "  [+] Claude Code installed"
            else
                echo "Warning: Claude Code installation failed. You can install it manually later:"
                echo "  curl -fsSL https://claude.ai/install.sh | bash"
            fi
        fi

        CORE_INSTALLED=true
        NEED_BREW=false
    else
        NEED_BREW=true
    fi

    # Check if 1Password accounts are configured
    if command -v op >/dev/null 2>&1; then
        OP_ACCOUNTS=$(op account list 2>/dev/null || echo "")
        NEED_OP_SETUP=false

        if ! echo "$OP_ACCOUNTS" | grep -q "lundstedts.1password.com"; then
            echo ""
            echo "  Note: Personal 1Password account not configured."
            echo "        Run: eval \$(op account add --address lundstedts.1password.com)"
            NEED_OP_SETUP=true
        fi

        if ! echo "$OP_ACCOUNTS" | grep -q "industryvault.1password.com"; then
            echo ""
            echo "  Note: Work 1Password account (industryvault) not configured."
            echo "        Run: eval \$(op account add --address industryvault.1password.com)"
            NEED_OP_SETUP=true
        fi

        if [[ "$NEED_OP_SETUP" == true ]]; then
            echo ""
            echo "  After adding accounts, restart Claude Code and Codex for MCP servers to work."
        fi
    fi

    configure_claude
fi

# macOS always uses Homebrew; Linux uses it only if needed or heavy installs requested
if [[ "$OS" == "macos" ]]; then
    NEED_BREW=true
elif [[ "$OS" == "linux" && "$INCLUDE_HEAVY" == true ]]; then
    NEED_BREW=true
elif [[ "$OS" == "linux" ]] && command -v brew >/dev/null 2>&1; then
    NEED_BREW=true
fi

# Ensure Homebrew is installed (macOS and Linuxbrew) and available in this shell
if [[ "$NEED_BREW" == true ]] && ! command -v brew >/dev/null 2>&1; then
    if [[ "$OS" == "macos" || "$OS" == "linux" ]]; then
        if [[ "$IS_INTERACTIVE" == false ]]; then
            echo "Error: Homebrew is required but not installed (non-interactive mode)."
            echo "Install Homebrew first or re-run with --interactive."
            exit 1
        fi
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    fi
fi

# Load brew into PATH for this script session
# Always reload after potential installation
if [[ "$NEED_BREW" == true && "$OS" == "macos" ]]; then
    if [ -x "/opt/homebrew/bin/brew" ]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [ -x "/usr/local/bin/brew" ]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi
elif [[ "$NEED_BREW" == true && "$OS" == "linux" ]]; then
    if [ -x "/home/linuxbrew/.linuxbrew/bin/brew" ]; then
        eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
        # shellcheck disable=SC2016  # Single quotes intentional - expand at shell load time
        append_line_if_missing "$HOME/.zshrc" 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv zsh)"'
        # shellcheck disable=SC2016
        append_line_if_missing "$HOME/.bashrc" 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv bash)"'
    elif [ -x "$HOME/.linuxbrew/bin/brew" ]; then
        eval "$("$HOME/.linuxbrew/bin/brew" shellenv)"
        # shellcheck disable=SC2016
        append_line_if_missing "$HOME/.zshrc" 'eval "$($HOME/.linuxbrew/bin/brew shellenv zsh)"'
        # shellcheck disable=SC2016
        append_line_if_missing "$HOME/.bashrc" 'eval "$($HOME/.linuxbrew/bin/brew shellenv bash)"'
    fi
fi

# Verify brew is now available
if [[ "$NEED_BREW" == true ]] && ! command -v brew >/dev/null 2>&1; then
    echo "Warning: Homebrew installation may have completed, but brew is not in PATH."
    echo "You may need to run: eval \"\$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)\""
    echo "Or add it to your shell configuration file."
fi

# Pre-authorize sudo on macOS to avoid password prompts during brew bundle (for casks like quarto)
if [[ "$OS" == "macos" ]] && command -v sudo >/dev/null 2>&1 && [[ "$IS_INTERACTIVE" == true ]]; then
    echo "Pre-authorizing sudo for brew bundle installation..."
    sudo -v || echo "Warning: sudo pre-authorization failed"
    # Keep sudo alive during brew bundle (refresh every 60 seconds)
    (
        while true; do
            sudo -n true 2>/dev/null || exit
            sleep 60
            kill -0 "$$" 2>/dev/null || exit
        done
    ) &
    SUDO_PID=$!
    disown "$SUDO_PID" 2>/dev/null || true
fi

# Install CLI tools from Brewfile on both macOS and Linux
if [[ "$NEED_BREW" == true ]] && command -v brew >/dev/null 2>&1; then
    BREW_BUNDLE_FLAGS=()
    if [[ "$IS_INTERACTIVE" == false ]]; then
        export HOMEBREW_NO_AUTO_UPDATE=1
        export HOMEBREW_NO_INSTALL_CLEANUP=1
        export HOMEBREW_NO_ENV_HINTS=1
        export HOMEBREW_NO_ANALYTICS=1
        BREW_BUNDLE_FLAGS+=(--quiet --no-upgrade)
    fi

    if [[ "$OS" == "macos" ]]; then
        if core_tools_installed; then
            echo "Core tools already installed, skipping brew bundle for formulas."
        else
            # Ensure required taps are added before bundle install
            echo "Adding required Homebrew taps..."
            brew tap columnar-tech/tap 2>/dev/null || echo "Note: columnar-tech/tap may already be added or unavailable"

            # Install CLI tools (brew formulas only)
            echo "Installing CLI tools from Brewfile..."
            TEMP_BREWFILE_FORMULAS=$(mktemp)
            sed -e '/^cask /d' \
                -e '/^mas /d' \
                -e '/brew "mas"/d' \
                "$HOME/dotfiles/homebrew/Brewfile" > "$TEMP_BREWFILE_FORMULAS"
            brew bundle "${BREW_BUNDLE_FLAGS[@]}" --file="$TEMP_BREWFILE_FORMULAS" || {
                echo ""
                echo "Warning: Some CLI packages may have failed to install."
                echo "You can retry later with:"
                echo "  brew bundle --file=\"$HOME/dotfiles/homebrew/Brewfile\""
            }
            rm -f "$TEMP_BREWFILE_FORMULAS"
        fi

        # Install npm global packages (node installed via brew)
        if command -v npm >/dev/null 2>&1; then
            echo "Installing npm global packages..."
            npm_packages=(
                "@anthropic-ai/claude-code"
                "@tigrisdata/cli"
            )
            for pkg in "${npm_packages[@]}"; do
                if npm ls -g "$pkg" >/dev/null 2>&1; then
                    continue
                fi
                npm install -g "$pkg" >/dev/null 2>&1 || {
                    echo "  Warning: Failed to install $pkg"
                }
            done
        fi

        configure_claude

        # Install heavyweight casks/mas only with --include-heavy flag
        if [[ "$INCLUDE_HEAVY" == true ]]; then
            echo ""
            echo "Installing macOS casks and Mac App Store apps..."
            brew bundle "${BREW_BUNDLE_FLAGS[@]}" --file="$HOME/dotfiles/homebrew/Brewfile" || {
                echo ""
                echo "Warning: Some packages may have failed to install."
                echo "This is normal for:"
                echo "  - Mac App Store apps (mas) if you're not signed in or apps are unavailable"
                echo "  - Some casks that require manual setup or are unavailable"
                echo ""
                echo "You can retry failed installations later with:"
                echo "  brew bundle --file=\"$HOME/dotfiles/homebrew/Brewfile\""
            }
        else
            echo "Skipping casks and Mac App Store apps (use --include-heavy to install)."
        fi
    elif [[ "$OS" == "linux" ]]; then
        if [[ "$CORE_INSTALLED" == false ]]; then
            echo "Installing core CLI tools for Linux via Homebrew..."
            brew bundle "${BREW_BUNDLE_FLAGS[@]}" --file="$HOME/dotfiles/homebrew/Brewfile.linux" || {
                echo "Warning: Some packages may have failed during core install."
            }
        else
            echo "Core tools already installed via apt, skipping Homebrew core install."
        fi

        # Install heavy Linux tools only with --include-heavy flag
        if [[ "$INCLUDE_HEAVY" == true ]]; then
            echo "Installing heavy Linux tools..."
            brew bundle "${BREW_BUNDLE_FLAGS[@]}" --file="$HOME/dotfiles/homebrew/Brewfile.linux-heavy" || {
                echo "Warning: Some heavy packages may have failed to install."
            }
        else
            echo "Skipping heavy Linux tools (use --include-heavy to install)."
        fi
    fi
else
    echo "Homebrew not available; skipping brew bundle."
fi

# Ensure GNU Stow is available
if ! command -v stow >/dev/null 2>&1; then
    if [[ "$OS" == "macos" ]]; then
        if ! command -v brew >/dev/null 2>&1; then
            echo "Homebrew is required to install stow. Install from https://brew.sh and re-run."
            exit 1
        fi
        brew list stow >/dev/null 2>&1 || brew install stow
    elif [[ "$OS" == "linux" ]]; then
        if command -v apt-get >/dev/null 2>&1; then
            run_privileged apt-get update && run_privileged apt-get install -y stow
        elif command -v dnf >/dev/null 2>&1; then
            run_privileged dnf install -y stow
        elif command -v yum >/dev/null 2>&1; then
            run_privileged yum install -y stow
        elif command -v pacman >/dev/null 2>&1; then
            run_privileged pacman -Sy --noconfirm stow
        elif command -v zypper >/dev/null 2>&1; then
            run_privileged zypper install -y stow
        else
            echo "Please install GNU Stow with your package manager and re-run."
            exit 1
        fi
    fi
fi

# Stow OS-specific folders
if [[ "$SKIP_STOW" == true ]]; then
    echo "Skipping stow as requested."
else
    # Back up conflicting agent-related files before stow --adopt can import them.
    backup_if_regular_file "$HOME/.claude/settings.json"
    backup_if_regular_file "$HOME/.claude/CLAUDE.md"
    backup_if_regular_file "$HOME/.codex/AGENTS.md"
    backup_if_regular_file "$HOME/.agents/AGENTS.md"

    if [[ "$OS" == "macos" ]]; then
        for folder in "${macos_folders[@]}"; do
            if [[ "$STOW_NO_PROMPT" != true ]]; then
                echo "About to stow '$folder' into $HOME (stow --adopt)."
                read -rp "Continue? [y/N]: " REPLY
                if [[ "$REPLY" != "y" && "$REPLY" != "Y" ]]; then
                    echo "Skipping $folder"
                    continue
                fi
            fi
            if [[ "$STOW_DRY_RUN" == true ]]; then
                stow --adopt --no-folding -R -n -t "$HOME" "$folder"
            else
                stow --adopt --no-folding -R -t "$HOME" "$folder"
            fi
        done
        # Ensure the permissions of the .config/op directory are set to 700
        mkdir -p "$HOME/.config/op"
        chmod 700 "$HOME/.config/op"
    elif [[ "$OS" == "linux" ]]; then
        # In non-interactive mode, remove common conflicting files that containers provide
        # (--adopt would overwrite dotfiles with container defaults, which we don't want)
        if [[ "$IS_INTERACTIVE" == false ]]; then
            for f in .zshrc .bashrc .profile .gitconfig; do
                if [[ -f "$HOME/$f" && ! -L "$HOME/$f" ]]; then
                    backup_path="$HOME/${f}.pre-dotfiles.$(date +%Y%m%d%H%M%S)"
                    mv "$HOME/$f" "$backup_path"
                    echo "Backed up $HOME/$f to $backup_path"
                fi
            done
        fi
        for folder in "${linux_folders[@]}"; do
            if [[ "$STOW_NO_PROMPT" != true ]]; then
                echo "About to stow '$folder' into $HOME (stow --adopt)."
                read -rp "Continue? [y/N]: " REPLY
                if [[ "$REPLY" != "y" && "$REPLY" != "Y" ]]; then
                    echo "Skipping $folder"
                    continue
                fi
            fi
            if [[ "$STOW_DRY_RUN" == true ]]; then
                stow --no-folding -R -n -t "$HOME" "$folder"
            elif [[ "$IS_INTERACTIVE" == true ]]; then
                stow --adopt --no-folding -R -t "$HOME" "$folder"
            else
                stow --no-folding -R -t "$HOME" "$folder"
            fi
        done
    fi

    # Link stow-managed skills now that agents package is deployed
    if [[ "$STOW_DRY_RUN" != true ]] && [ -d "$HOME/.agents/skills/bootstrap-project" ]; then
        mkdir -p "$HOME/.claude/skills" "$HOME/.codex/skills"
        link_skill bootstrap-project
    fi
fi

# Install VS Code extensions from extensions list
if command -v code >/dev/null 2>&1; then
    VSCODE_EXTENSIONS="$HOME/Library/Application Support/Code/User/extensions.txt"
    if [ -f "$VSCODE_EXTENSIONS" ]; then
        echo "Installing VS Code extensions..."
        while IFS= read -r ext || [ -n "$ext" ]; do
            [ -z "$ext" ] && continue
            code --install-extension "$ext" --force >/dev/null 2>&1 && echo "  [+] $ext" || echo "  [!] $ext failed"
        done < "$VSCODE_EXTENSIONS"
    fi
fi

# Copy example config files if they don't exist
echo ""
echo "Setting up local config templates..."
if [ -f "$HOME/dotfiles/aws/.aws/config.example" ] && [ ! -f "$HOME/dotfiles/aws/.aws/config" ]; then
    cp "$HOME/dotfiles/aws/.aws/config.example" "$HOME/dotfiles/aws/.aws/config"
    echo "  ✓ Created aws/.aws/config from example (please customize)"
fi
if [ -f "$HOME/dotfiles/ssh/.ssh/config.example" ] && [ ! -f "$HOME/dotfiles/ssh/.ssh/config" ]; then
    cp "$HOME/dotfiles/ssh/.ssh/config.example" "$HOME/dotfiles/ssh/.ssh/config"
    echo "  ✓ Created ssh/.ssh/config from example (please customize)"
fi

echo ""
echo "Dotfiles installation complete for $OS"
echo ""
echo "Next steps:"
echo "  1. Start a new shell session to use zsh with your new prompt:"
echo "     - Open a new terminal tab/window, or"
echo "     - Run: exec zsh"
echo ""
if [ -f "$HOME/dotfiles/aws/.aws/config" ] || [ -f "$HOME/dotfiles/ssh/.ssh/config" ]; then
    echo "  2. Customize local configs (optional):"
    [ -f "$HOME/dotfiles/aws/.aws/config" ] && echo "     - Edit ~/dotfiles/aws/.aws/config with your AWS settings"
    [ -f "$HOME/dotfiles/ssh/.ssh/config" ] && echo "     - Edit ~/dotfiles/ssh/.ssh/config with your SSH hosts"
    echo ""
fi

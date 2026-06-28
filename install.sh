#!/bin/bash
set -euo pipefail

# --- Args ---
INSTALL_APPS=false
DRY_RUN=false
SKIP_STOW=false
SKIP_AGENTS=false
TAILSCALE_SSH=false
UPGRADE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --apps)           INSTALL_APPS=true; shift ;;
        --dry-run)        DRY_RUN=true; shift ;;
        --no-prompt)      shift ;;  # accepted for backwards compat, no longer needed
        --skip-stow)      SKIP_STOW=true; shift ;;
        --skip-agents)    SKIP_AGENTS=true; shift ;;
        --tailscale-ssh)  TAILSCALE_SSH=true; shift ;;
        --upgrade)        UPGRADE=true; shift ;;
        *)
            echo "Usage: $0 [--apps] [--dry-run] [--no-prompt] [--skip-stow] [--skip-agents] [--tailscale-ssh] [--upgrade]"
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

# want <cmd>: true if the tool should be (re)installed — either it's missing, or
# --upgrade was passed. The CLI installers always fetch the latest GitHub release
# (or run the vendor install script), so forcing a reinstall is what "upgrade"
# means here; there's no per-tool version parsing to drift. Without --upgrade,
# present tools are skipped so re-runs stay fast. Replaces bare `need` in the CLI
# tool / agent guards, which otherwise skip anything already on PATH forever.
want() { need "$1" || [[ "$UPGRADE" == true ]]; }

# Set GITHUB_TOKEN from gh CLI if available (raises rate limit from 60 to 5000/hr)
if [[ -z "${GITHUB_TOKEN:-}" ]] && command -v gh >/dev/null 2>&1; then
    GITHUB_TOKEN=$(gh auth token 2>/dev/null) || true
    [[ -n "$GITHUB_TOKEN" ]] && export GITHUB_TOKEN
fi

# Download an asset URL, extract it, and place the binary in ~/.local/bin.
# Shared by install_github_binary (API path) and install_release_asset (direct path).
# Usage: _fetch_and_place <asset_url> <binary_name> <path_inside_archive>
_fetch_and_place() {
    local asset_url="$1" bin_name="$2" inner_path="$3"
    local tmp asset_name
    asset_name="${asset_url##*/}"
    tmp=$(mktemp -d)

    local -a dl_opts=(-fsSL)
    [[ -n "${GITHUB_TOKEN:-}" ]] && dl_opts+=(-H "Authorization: token $GITHUB_TOKEN")
    if ! curl "${dl_opts[@]}" "$asset_url" -o "$tmp/$asset_name"; then
        echo "  [!] $bin_name: download failed"; rm -rf "$tmp"; return 1
    fi
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
    rm -rf "$tmp"
    echo "  [+] $bin_name"
}

# Download a known release asset directly from github.com (NOT api.github.com),
# so it doesn't consume the unauthenticated 60/hr/IP API rate limit. Use this for
# tools whose asset filename is version-less (the /latest/download/ redirect needs
# the literal name). For version-stamped assets, use install_github_binary instead.
# Usage: install_release_asset <owner/repo> <asset_name> <binary_name> [<path_inside_archive>]
install_release_asset() {
    local repo="$1" asset_name="$2" bin_name="$3"
    local inner_path="${4:-$bin_name}"
    _fetch_and_place "https://github.com/${repo}/releases/latest/download/${asset_name}" "$bin_name" "$inner_path"
}

# Fetch latest GitHub release asset via the API (resolves version-stamped asset
# names), extract, and place binary in ~/.local/bin. The API is rate-limited to
# 60/hr per IP when unauthenticated (no GITHUB_TOKEN), so prefer install_release_asset
# for version-less assets. Returns non-zero on failure so callers don't cascade silently.
# Usage: install_github_binary <owner/repo> <asset_pattern> <binary_name> [<path_inside_archive>]
#   asset_pattern: grep -E pattern to match the asset filename (use ARCH/OS placeholders before calling)
#   binary_name: final name in ~/.local/bin
#   path_inside_archive: optional path to the binary inside a tar/zip (default: same as binary_name)
install_github_binary() {
    local repo="$1" pattern="$2" bin_name="$3"
    local inner_path="${4:-$bin_name}"
    local asset_url api_response
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
        # Distinguish rate-limit from a genuine missing asset so it's not a silent skip.
        if echo "$api_response" | grep -q "API rate limit exceeded"; then
            echo "  [!] $bin_name: GitHub API rate limit hit (unauthenticated) — not installed"
        else
            echo "  [!] $bin_name: no matching release asset"
        fi
        return 1
    fi
    _fetch_and_place "$asset_url" "$bin_name" "$inner_path"
}

# Quarto: install tarball to ~/.local/share/quarto, symlink binary to ~/.local/bin.
# Replaces the Brewfile cask, whose .pkg installer required sudo on every run.
install_quarto() {
    local arch quarto_arch
    arch=$(uname -m)
    case "$OS-$arch" in
        macos-*)        quarto_arch="macos" ;;
        linux-x86_64)   quarto_arch="linux-amd64" ;;
        linux-aarch64)  quarto_arch="linux-arm64" ;;
        *) echo "  [!] quarto: unsupported $OS-$arch"; return 1 ;;
    esac
    local api="https://api.github.com/repos/quarto-dev/quarto-cli/releases/latest"
    local -a opts=(-fsSL)
    [[ -n "${GITHUB_TOKEN:-}" ]] && opts+=(-H "Authorization: token $GITHUB_TOKEN")
    local resp version url
    resp=$(curl "${opts[@]}" "$api" 2>/dev/null) || { echo "  [!] quarto: API fetch failed"; return 1; }
    version=$(echo "$resp" | grep -oE '"tag_name": "v[^"]+"' | head -1 | sed 's/.*"v\([^"]*\)".*/\1/')
    [[ -z "$version" ]] && { echo "  [!] quarto: no version in release"; return 1; }
    url=$(echo "$resp" \
        | grep -oE "\"browser_download_url\": \"[^\"]+\"" \
        | grep -F "quarto-${version}-${quarto_arch}.tar.gz" \
        | head -1 \
        | sed 's/"browser_download_url": "//;s/"//')
    [[ -z "$url" ]] && { echo "  [!] quarto: no asset for $quarto_arch"; return 1; }

    local dest="$HOME/.local/share/quarto"
    if [[ -L "$LOCAL_BIN/quarto" && -d "$dest/quarto-$version" ]]; then
        echo "  [+] quarto $version (up to date)"
        return 0
    fi

    local tmp; tmp=$(mktemp -d)
    if curl "${opts[@]}" "$url" -o "$tmp/q.tgz"; then
        mkdir -p "$dest"
        # Drop older versions and any unversioned legacy layout
        find "$dest" -maxdepth 1 -mindepth 1 -exec rm -rf {} +
        mkdir -p "$dest/quarto-$version"
        # Linux tarballs wrap contents in quarto-X.Y.Z/; macOS tarball doesn't.
        if tar -tzf "$tmp/q.tgz" | head -1 | grep -q "^quarto-${version}/"; then
            tar -xzf "$tmp/q.tgz" -C "$dest/quarto-$version" --strip-components=1
        else
            tar -xzf "$tmp/q.tgz" -C "$dest/quarto-$version"
        fi
        ln -sf "$dest/quarto-$version/bin/quarto" "$LOCAL_BIN/quarto"
        echo "  [+] quarto $version"
    else
        echo "  [!] quarto: download failed"
    fi
    rm -rf "$tmp"
}

# --- install_system_deps ---
install_system_deps() {
    echo "=== System dependencies ==="
    if [[ "$OS" == "linux" ]]; then
        local apt_needed=()
        for pkg_cmd in stow:stow zsh:zsh git:git curl:curl unzip:unzip cron:cron; do
            local cmd="${pkg_cmd##*:}" pkg="${pkg_cmd%%:*}"
            need "$cmd" && apt_needed+=("$pkg")
        done
        if [[ ${#apt_needed[@]} -gt 0 ]]; then
            echo "  Installing ${apt_needed[*]}..."
            $SUDO apt-get update -qq 2>/dev/null || true
            $SUDO apt-get install -y -qq "${apt_needed[@]}"
        else
            echo "  All system packages present"
        fi
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

    # Install tools to ~/.local/bin. Skip tools already present (at any path)
    # to avoid redundant downloads — exeuntu ships with several of these.
    # With --upgrade, reinstall every tool at latest regardless of presence
    # (and shadow any system copy via ~/.local/bin's PATH precedence).
    local pids=()
    local fnm_asset
    case "$OS-$arch" in
        macos-*)       fnm_asset="fnm-macos" ;;
        linux-aarch64) fnm_asset="fnm-arm64" ;;
        linux-x86_64)  fnm_asset="fnm-linux" ;;
    esac

    # Curl install scripts
    if want starship; then
        (curl -fsSL https://starship.rs/install.sh | sh -s -- --yes --bin-dir="$LOCAL_BIN" >/dev/null 2>&1 && echo "  [+] starship" || echo "  [!] starship failed") &
        pids+=($!)
    else echo "  [=] starship"; fi
    if want uv; then
        (curl -fsSL https://astral.sh/uv/install.sh | env CARGO_HOME="$HOME/.local" sh >/dev/null 2>&1 && echo "  [+] uv" || echo "  [!] uv failed") &
        pids+=($!)
    else echo "  [=] uv"; fi
    # atuin installs to ~/.atuin/bin (not ~/.local/bin), so the presence check
    # also probes that path; --upgrade forces a reinstall regardless.
    if { need atuin && [[ ! -x "$HOME/.atuin/bin/atuin" ]]; } || [[ "$UPGRADE" == true ]]; then
        (curl -fsSL https://github.com/atuinsh/atuin/releases/latest/download/atuin-installer.sh | sh -s -- --no-modify-path >/dev/null 2>&1 && echo "  [+] atuin" || echo "  [!] atuin failed") &
        pids+=($!)
    else echo "  [=] atuin"; fi
    local direnv_os; case "$OS" in macos) direnv_os="darwin" ;; linux) direnv_os="linux" ;; esac
    if want direnv; then
        (install_release_asset "direnv/direnv" "direnv.${direnv_os}-${gh_arch}" "direnv" "direnv.${direnv_os}-${gh_arch}") &
        pids+=($!)
    else echo "  [=] direnv"; fi
    if want zoxide; then
        (install_github_binary "ajeetdsouza/zoxide" "zoxide-.*-${target_triple}.*\\.tar\\.gz" "zoxide") &
        pids+=($!)
    else echo "  [=] zoxide"; fi
    local tigris_arch; case "$arch" in arm64|aarch64) tigris_arch="arm64" ;; x86_64) tigris_arch="x64" ;; esac
    if want tigris; then
        (install_release_asset "tigrisdata/cli" "tigris-${direnv_os}-${tigris_arch}.tar.gz" "tigris" "tigris-${direnv_os}-${tigris_arch}") &
        pids+=($!)
    else echo "  [=] tigris"; fi
    # archil: CLI on Linux, macOS app installed separately (interactive prompt)
    if [[ "$OS" == "linux" ]] && want archil; then
        (curl -fsSL https://archil.com/install | sh >/dev/null 2>&1 && echo "  [+] archil" || echo "  [!] archil failed") &
        pids+=($!)
    fi
    if want fnm; then
        (install_release_asset "Schniz/fnm" "${fnm_asset}.zip" "fnm" "fnm") &
        pids+=($!)
    else echo "  [=] fnm"; fi

    # GitHub release binaries
    if want bat; then
        (install_github_binary "sharkdp/bat" "bat-v.*-${target_triple}.*\\.tar\\.gz" "bat") &
        pids+=($!)
    else echo "  [=] bat"; fi
    if want fzf; then
        (install_github_binary "junegunn/fzf" "fzf-.*-${gh_os}_${gh_arch}\\.tar\\.gz" "fzf" "fzf") &
        pids+=($!)
    else echo "  [=] fzf"; fi
    if want rg; then
        (install_github_binary "BurntSushi/ripgrep" "ripgrep-.*-${target_triple}.*\\.tar\\.gz" "rg") &
        pids+=($!)
    else echo "  [=] rg"; fi
    local jq_os; case "$OS" in macos) jq_os="macos" ;; linux) jq_os="linux" ;; esac
    if want jq; then
        (install_github_binary "jqlang/jq" "jq-${jq_os}-${gh_arch}\"$" "jq" "jq-${jq_os}-${gh_arch}") &
        pids+=($!)
    else echo "  [=] jq"; fi
    if want yq; then
        (install_github_binary "mikefarah/yq" "yq_${gh_os}_${gh_arch}\"$" "yq" "yq_${gh_os}_${gh_arch}") &
        pids+=($!)
    else echo "  [=] yq"; fi
    if want gh; then
        (install_github_binary "cli/cli" "gh_.*_${gh_cli_os}_${gh_arch}\\.(tar\\.gz|zip)" "gh") &
        pids+=($!)
    else echo "  [=] gh"; fi
    if want duckdb; then
        (install_github_binary "duckdb/duckdb" "duckdb_cli-${duckdb_os}-${gh_arch}\\.zip" "duckdb" "duckdb") &
        pids+=($!)
    else echo "  [=] duckdb"; fi
    if want carapace; then
        (install_github_binary "carapace-sh/carapace-bin" "carapace-bin_.*_${gh_os}_${gh_arch}\\.tar\\.gz" "carapace" "carapace") &
        pids+=($!)
    else echo "  [=] carapace"; fi
    if want cship; then
        (install_github_binary "stephenleo/cship" "cship-${target_triple}" "cship" "cship-${target_triple}") &
        pids+=($!)
    else echo "  [=] cship"; fi
    # quarto compares the installed version dir against latest, so it's already
    # upgrade-aware; want() just lets --upgrade force the API check even when present.
    if want quarto; then
        (install_quarto) &
        pids+=($!)
    else echo "  [=] quarto"; fi

    # Wait for all parallel installs
    for pid in "${pids[@]+"${pids[@]}"}"; do
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
        echo "  [!] fnm not installed (see CLI tools section above) — skipping node setup"
        echo "      Consequence: no node/npx, so agent skills will be skipped too. Re-run install.sh once fnm is present."
        return 0
    fi
    eval "$(fnm env --shell bash)"
    # fnm install --lts pulls the newest LTS, so it doubles as the upgrade path.
    if want node; then
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

    # disk: Archil's npm-distributed CLI, complements the native `archil` CLI.
    # npm install -g always resolves latest, so want() makes --upgrade refresh it.
    if command -v npm >/dev/null 2>&1 && want disk; then
        npm install -g disk >/dev/null 2>&1 && echo "  [+] disk" || echo "  [!] disk install failed"
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

    # --- SSH config (complete write) ---
    local ssh_config="$HOME/.ssh/config"
    mkdir -p "$HOME/.ssh/sockets"
    chmod 700 "$HOME/.ssh"

    # Migration: remove stow symlink (ssh package no longer manages this file)
    [[ -L "$ssh_config" ]] && rm "$ssh_config"

    # Copy exe_dev.pub from repo (needed for IdentityFile key pinning).
    # Remove any stow symlink first — cp follows symlinks and would
    # overwrite the repo source file instead of creating a real copy.
    local exe_pub_src="$DOTFILES_DIR/ssh/exe_dev.pub"
    if [[ -f "$exe_pub_src" ]]; then
        [[ -L "$HOME/.ssh/exe_dev.pub" ]] && rm "$HOME/.ssh/exe_dev.pub"
        cp "$exe_pub_src" "$HOME/.ssh/exe_dev.pub"
        chmod 644 "$HOME/.ssh/exe_dev.pub"
    fi

    # Helper used by ssh_config `Match exec` — exits 0 if the canonicalized
    # tailnet peer carries the named tag. Lets a single Match block dynamically
    # apply exe.dev settings (User exedev, IdentityFile, etc.) to ANY current
    # or future tag:dev VM without re-running install.sh per host.
    cat > "$LOCAL_BIN/ssh-tailnet-tagged" <<'HELPEREOF'
#!/bin/sh
# Usage: ssh-tailnet-tagged <hostname> <tag>
host="$1"
tag="$2"
short="${host%%.*}"
command -v tailscale >/dev/null 2>&1 || exit 1
command -v jq >/dev/null 2>&1 || exit 1
tailscale status --json 2>/dev/null \
    | jq -e --arg short "$short" --arg tag "$tag" \
        '.Peer[]? | select(.HostName == $short) | (.Tags // []) | index($tag)' \
    >/dev/null 2>&1
HELPEREOF
    chmod +x "$LOCAL_BIN/ssh-tailnet-tagged"

    # Detect tailnet domain for hostname canonicalization (used on both OSes
    # so `ssh <shortname>` matches `Host *.ts.net` / Match host *.ts.net).
    local tailnet_domain=""
    if command -v tailscale >/dev/null 2>&1 && tailscale status >/dev/null 2>&1; then
        tailnet_domain=$(tailscale status --json 2>/dev/null \
            | jq -r '.MagicDNSSuffix // empty' 2>/dev/null) || true
    fi

    if [[ "$OS" == "macos" ]]; then
        cat > "$ssh_config" <<'SSHEOF'
# Managed by dotfiles/install.sh — do not edit manually.
SSHEOF

        if [[ -n "$tailnet_domain" ]]; then
            cat >> "$ssh_config" <<SSHEOF

CanonicalizeHostname yes
CanonicalDomains $tailnet_domain
CanonicalizeMaxDots 0
SSHEOF
        fi

        cat >> "$ssh_config" <<SSHEOF

Host github.com
  ControlMaster auto
  ControlPath ~/.ssh/sockets/%r@%h-%p
  ControlPersist 600

Host exe.dev *.exe.xyz
  ControlMaster auto
  ControlPath ~/.ssh/sockets/%r@%h-%p
  ControlPersist 600
  IdentitiesOnly yes
  IdentityFile ~/.ssh/exe_dev.pub

Host *.exe.xyz
  User exedev
# Tigris/Readwise MCP OAuth: tunnel on demand with
#   ssh -L 8765:localhost:8765 <vm>.exe.xyz
# An always-on LocalForward here collides across multiplexed *.exe.xyz
# masters (2nd host: "port 8765 already in use" -> broken control master).

# exe.dev VMs reached by Tailscale name: detected dynamically by tag,
# so new VMs Just Work without re-running install.sh.
# Host keys skipped — WireGuard already authenticates the peer.
Match host *.ts.net exec "$LOCAL_BIN/ssh-tailnet-tagged %h tag:dev"
  User exedev
  IdentitiesOnly yes
  IdentityFile ~/.ssh/exe_dev.pub
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  LogLevel ERROR

Host *.ts.net
  ForwardAgent yes
SSHEOF

        if [[ -S "$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock" ]]; then
            cat >> "$ssh_config" <<'SSHEOF'

Host *
  IdentityAgent "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
SSHEOF
        fi

        echo "  [+] SSH config (macOS)"

    elif [[ "$OS" == "linux" ]]; then
        cat > "$ssh_config" <<'SSHEOF'
# Managed by dotfiles/install.sh — do not edit manually.
SSHEOF

        # CanonicalizeHostname must come BEFORE Host blocks. OpenSSH's
        # "first obtained value" rule means Host blocks otherwise get
        # evaluated against the short name, before canonicalization can
        # rewrite it. Verified empirically: with these lines in the
        # middle of the file, `ssh gitlake` from another VM falls through
        # to default StrictHostKeyChecking and fails on host-key change.
        if [[ -n "$tailnet_domain" ]]; then
            cat >> "$ssh_config" <<SSHEOF

CanonicalizeHostname yes
CanonicalDomains $tailnet_domain
CanonicalizeMaxDots 0
SSHEOF
        fi

        cat >> "$ssh_config" <<SSHEOF

Host github.com
  Hostname ssh.github.com
  Port 443
  User git

Host exe.dev *.exe.xyz
  ControlMaster auto
  ControlPath ~/.ssh/sockets/%r@%h-%p
  ControlPersist 600
  IdentitiesOnly yes
  IdentityFile ~/.ssh/exe_dev.pub

Host *.exe.xyz
  User exedev

# Cross-VM ssh by Tailscale name: same dynamic tag check as macOS.
Match host *.ts.net exec "$LOCAL_BIN/ssh-tailnet-tagged %h tag:dev"
  User exedev
  IdentitiesOnly yes
  IdentityFile ~/.ssh/exe_dev.pub
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  LogLevel ERROR
SSHEOF

        echo "  [+] SSH config (Linux)"

        # GitHub known host
        if ! grep -q 'ssh.github.com' "$HOME/.ssh/known_hosts" 2>/dev/null; then
            ssh-keyscan -p 443 ssh.github.com >> "$HOME/.ssh/known_hosts" 2>/dev/null
            echo "  [+] GitHub known host"
        fi
    fi

    chmod 600 "$ssh_config"

    # Pre-seed exe.dev host key (all VMs share one key; wildcard avoids
    # host-key churn on VM rebuild and StrictHostKeyChecking prompts)
    local known_hosts="$HOME/.ssh/known_hosts"
    touch "$known_hosts"
    local exe_rsa_key="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDEKtEcRW8OBtro5B/MG+EaisD+ZVwwHFa5m7M8wFwBlMmPJJssY+1aGBRW3b9InAeCnTU2Kt7gazqbg/9od1KnK6x5piQNVQZ4C/lrjsC2ScBrOydnw9ry9G2+voFCAk+dQGabIrIT6gqqDJNOqxgFiG/lA3Xx6KwpfwI2BH5f3ab2fHCR2BGAC5jlB2RJXPgly80hMxYEHqexhJxYRwC+deeLrQSG795we9rSzPmdz58t9+9jLTKkyyqWKe/hmBvty1AYrEmRsefu6/TUrIGi/UWJfa+RBIQtFgWqN6xT1F6rRwELeVOfwwr5tZbsmgWY5frZU3EOtVWcF7Ve3gfL"
    # Remove stale per-VM entries and old exe.dev entries, then add fresh wildcard
    sed -i.bak '/\.exe\.xyz/d; /^exe\.dev /d' "$known_hosts" && rm -f "${known_hosts}.bak"
    echo "exe.dev $exe_rsa_key" >> "$known_hosts"
    echo "*.exe.xyz $exe_rsa_key" >> "$known_hosts"
    echo "  [+] exe.dev host key in known_hosts"

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
        # Work repos under ~/github/<org>/ pick up .gitconfig_work
        # via includeIf in .gitconfig (stowed); personal override for
        # ~/github/kylelundstedt/.
        cat > "$git_config_local" <<'EOF'
[user]
name = Kyle G. Lundstedt
email = kyle@lundstedt.us
EOF
        mkdir -p "$HOME/github/kylelundstedt"
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
        # Ensure zsh is listed in /etc/shells (required by chsh)
        if ! grep -qx "$desired_shell" /etc/shells 2>/dev/null; then
            echo "$desired_shell" | sudo tee -a /etc/shells >/dev/null 2>/dev/null || true
        fi
        if [[ "$(id -u)" -eq 0 ]]; then
            chsh -s "$desired_shell" 2>/dev/null \
                || usermod -s "$desired_shell" "$(whoami)" 2>/dev/null \
                || echo "  Note: could not change shell to zsh"
        else
            sudo chsh -s "$desired_shell" "$(whoami)" 2>/dev/null \
                || sudo usermod -s "$desired_shell" "$(whoami)" 2>/dev/null \
                || chsh -s "$desired_shell" 2>/dev/null \
                || echo "  Note: could not change shell to zsh"
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

    # agents/.claude/settings.json is gitignored (Claude Code mutates it at runtime).
    # Seed it from the example so stow has something to link.
    local claude_settings="$DOTFILES_DIR/agents/.claude/settings.json"
    if [[ ! -f "$claude_settings" && -f "${claude_settings}.example" ]]; then
        cp "${claude_settings}.example" "$claude_settings"
        echo "  Seeded agents/.claude/settings.json from example"
    fi

    # Always stow these
    local packages=("git" "zsh" "starship" "agents")

    # Platform-specific
    if [[ "$OS" == "macos" ]]; then
        packages+=("1Password" "ghostty" "launchd" "vscode" "zed" "homebrew")
    else
        packages+=("aws")
    fi

    # Backup files/symlinks that conflict with the agents stow package.
    # On boldsoftware/exeuntu (default exe.dev image), .claude/CLAUDE.md and
    # .codex/AGENTS.md are pre-created as absolute symlinks into Bold's
    # ~/.config/shelley/ tree. Foreign symlinks must be moved aside before
    # stow will write its own; stow-created symlinks (target inside
    # $DOTFILES_DIR) are left alone so reruns are idempotent.
    for f in "$HOME/.claude/settings.json" "$HOME/.claude/CLAUDE.md" "$HOME/.codex/AGENTS.md" "$HOME/.agents/AGENTS.md"; do
        if [[ -f "$f" && ! -L "$f" ]]; then
            mv "$f" "${f}.pre-dotfiles.$(date +%Y%m%d%H%M%S)"
            echo "  Backed up $f"
        elif [[ -L "$f" ]]; then
            target=$(readlink -f "$f" 2>/dev/null || true)
            if [[ -n "$target" && "$target" != "$DOTFILES_DIR"/* ]]; then
                mv "$f" "${f}.pre-dotfiles.$(date +%Y%m%d%H%M%S)"
                echo "  Backed up foreign symlink $f → $target"
            fi
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

    # Skip-worktree on Zed settings so Zed's UI mutations (ssh_connections, etc.)
    # don't show in git status. To edit the tracked file:
    #   git update-index --no-skip-worktree zed/.config/zed/settings.json
    if [[ "$OS" == "macos" ]]; then
        local zed_settings="zed/.config/zed/settings.json"
        if git -C "$DOTFILES_DIR" ls-files --error-unmatch "$zed_settings" &>/dev/null; then
            git -C "$DOTFILES_DIR" update-index --skip-worktree "$zed_settings" 2>/dev/null || true
        fi
    fi
}

# --- setup_agents ---
setup_agents() {
    echo ""
    echo "=== Agents ==="

    # Claude Code CLI (native installer, npm fallback for arm64 Linux).
    # The native installer reinstalls latest, so --upgrade forces a refresh.
    if { need claude && [[ ! -f "$LOCAL_BIN/claude" ]]; } || [[ "$UPGRADE" == true ]]; then
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

    # Codex CLI — native binary preferred (brew cask on macOS, GitHub release
    # tarball on Linux). The npm wrapper is a last-resort fallback: it ships
    # the same native binary inside an npm package, but partial installs leave
    # an empty vendor dir and a broken `codex` on PATH (we hit this once).
    if want codex; then
        if [[ "$OS" == "macos" ]] && command -v brew >/dev/null 2>&1; then
            # `brew install --cask` is a no-op when present, so --upgrade on an
            # already-installed codex routes through `brew upgrade` instead.
            if command -v codex >/dev/null 2>&1 && [[ "$UPGRADE" == true ]]; then
                echo "  Upgrading Codex CLI (brew cask)..."
                brew upgrade --cask codex >/dev/null 2>&1 \
                    && echo "  [+] Codex CLI (brew, upgraded)" \
                    || echo "  [=] Codex CLI (brew, up to date)"
            else
                echo "  Installing Codex CLI (brew cask)..."
                brew install --cask codex >/dev/null 2>&1 \
                    && echo "  [+] Codex CLI (brew)" \
                    || echo "  [!] Codex brew install failed"
            fi
        elif [[ "$OS" == "linux" ]]; then
            local codex_arch
            case "$(uname -m)" in
                x86_64)  codex_arch="x86_64" ;;
                aarch64) codex_arch="aarch64" ;;
                *) echo "  [!] Codex: unsupported arch $(uname -m)"; codex_arch="" ;;
            esac
            if [[ -n "$codex_arch" ]]; then
                echo "  Installing Codex CLI (native binary)..."
                install_github_binary "openai/codex" \
                    "codex-${codex_arch}-unknown-linux-musl\\.tar\\.gz" \
                    "codex" \
                    "codex-${codex_arch}-unknown-linux-musl"
            fi
        elif command -v npm >/dev/null 2>&1; then
            echo "  Installing Codex CLI (npm fallback)..."
            npm install -g @openai/codex >/dev/null 2>&1 \
                && echo "  [+] Codex CLI (npm)" \
                || echo "  [!] Codex npm install failed"
        else
            echo "  [!] Codex CLI: no install method available"
        fi
    fi

    # 1Password CLI (Linux only — macOS gets it from Brewfile cask).
    # The download resolves the latest version, so want() makes --upgrade refresh it.
    if want op && [[ "$OS" == "linux" ]]; then
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

    # personal-mcp local hub (hub-mcp): unlike the remote servers above, it runs on
    # klundstedt-mini and is reached locally there or over the tailnet elsewhere. Probe
    # reachability so it's only registered where it actually works (skips exe.dev VMs and
    # off-tailnet machines). Empty hub_url => not registered on this machine.
    local hub_url=""
    if [[ "$OS" == "macos" ]]; then
        if [[ "$(scutil --get LocalHostName 2>/dev/null)" == "klundstedt-mini" ]]; then
            hub_url="http://127.0.0.1:8765/mcp"
        elif curl -s -m 3 -o /dev/null https://klundstedt-mini.dojo-sun.ts.net/mcp 2>/dev/null; then
            hub_url="https://klundstedt-mini.dojo-sun.ts.net/mcp"
        fi
    fi

    # --- Claude Code ---
    if command -v claude >/dev/null 2>&1; then
        # Remove stale or migrated servers before re-adding with correct URLs.
        # On Linux, motherduck migrates from OAuth to exe.dev proxy.
        for srv in dlt motherduck github-home github-work tigris readwise hub-mcp; do
            claude mcp remove --scope user "$srv" >/dev/null 2>&1 || true
        done

        # On exe.dev VMs, use HTTP proxy integrations for servers that
        # support static tokens (no secrets on VM disk). OAuth-only servers
        # (Tigris, Readwise) need a one-time browser dance over an explicit
        # `ssh -L 8765:localhost:8765 <vm>.exe.xyz` tunnel (not always-on).
        if [[ "$OS" == "linux" ]]; then
            claude mcp add --transport http --scope user motherduck https://motherduck-mcp.int.exe.xyz/mcp >/dev/null 2>&1 || true
            claude mcp add --transport http --scope user github-home https://github-mcp-home.int.exe.xyz/mcp/ >/dev/null 2>&1 || true
            claude mcp add --transport http --scope user github-work https://github-mcp-work.int.exe.xyz/mcp/ >/dev/null 2>&1 || true
            # OAuth-only servers (first-use browser auth via an explicit -L 8765 tunnel)
            claude mcp add --transport http --scope user tigris https://mcp.storage.dev/mcp >/dev/null 2>&1 || true
            claude mcp add --transport http --scope user readwise https://mcp2.readwise.io/mcp >/dev/null 2>&1 || true
            echo "  [+] MCP servers (3 via exe.dev proxy, 2 OAuth)"
        else
            # macOS: OAuth servers + GitHub PATs from 1Password
            claude mcp add --transport http --scope user motherduck https://api.motherduck.com/mcp >/dev/null 2>&1 || true
            claude mcp add --transport http --scope user tigris https://mcp.storage.dev/mcp >/dev/null 2>&1 || true
            claude mcp add --transport http --scope user readwise https://mcp2.readwise.io/mcp >/dev/null 2>&1 || true
            if [[ -n "$hub_url" ]]; then
                claude mcp add --transport http --scope user hub-mcp "$hub_url" >/dev/null 2>&1 \
                    && echo "  [+] hub-mcp ($hub_url)" || true
            fi
            if [[ "$op_configured" == true ]]; then
                local pat_home pat_work
                pat_home=$(op read "op://Private/GitHub PAT Home/token" --account lundstedts.1password.com 2>/dev/null) || true
                pat_work=$(op read "op://Employee/GitHub PAT IV/token" --account industryvault.1password.com 2>/dev/null) || true
                [[ -n "$pat_home" ]] && claude mcp add-json --scope user github-home \
                    "{\"type\":\"http\",\"url\":\"https://api.githubcopilot.com/mcp/\",\"headers\":{\"Authorization\":\"Bearer $pat_home\"}}" >/dev/null 2>&1 || true
                [[ -n "$pat_work" ]] && claude mcp add-json --scope user github-work \
                    "{\"type\":\"http\",\"url\":\"https://api.githubcopilot.com/mcp/\",\"headers\":{\"Authorization\":\"Bearer $pat_work\"}}" >/dev/null 2>&1 || true

                # sync-repos.sh reads per-org GitHub PATs from the local login
                # Keychain (fine-grained PATs are scoped per owner; gh's Home
                # token can't list IndustryVault/iv-cmg). Provision them from
                # 1Password so the nightly repo sync works on every Mac. The
                # Keychain is local per-machine, so this runs on each install.
                # pat_work is the IV token (reused); -T allows the `security`
                # tool to read it back non-interactively from the launchd job.
                local pat_ivcmg kc_added=0
                pat_ivcmg=$(op read "op://Employee/GitHub PAT IV-CMG/token" --account industryvault.1password.com 2>/dev/null) || true
                [[ -n "$pat_work" ]]  && security add-generic-password -a "$USER" -s "sync-repos:IndustryVault" -T /usr/bin/security -U -w "$pat_work"  2>/dev/null && kc_added=$((kc_added+1)) || true
                [[ -n "$pat_ivcmg" ]] && security add-generic-password -a "$USER" -s "sync-repos:iv-cmg"        -T /usr/bin/security -U -w "$pat_ivcmg" 2>/dev/null && kc_added=$((kc_added+1)) || true
                [[ "$kc_added" -gt 0 ]] && echo "  [+] sync-repos org PATs → Keychain ($kc_added)"

                # tigris-backup (klundstedt-mini only): provision the nightly
                # backup's rclone key + crypt password/salt + healthcheck URL into
                # the login Keychain (service tigris-backup:*) from 1Password, so
                # the unattended launchd job reads them non-interactively. Items
                # live in the industryvault account, Personal vault.
                if [[ "$(scutil --get LocalHostName 2>/dev/null)" == "klundstedt-mini" ]]; then
                    local tb_acc=industryvault.1password.com tb_n=0
                    local tb_keyid tb_keysec tb_cpw tb_csalt tb_hc
                    tb_keyid=$(op read "op://Personal/Tigris mini-backup rclone key/access_key_id" --account "$tb_acc" 2>/dev/null) || true
                    tb_keysec=$(op read "op://Personal/Tigris mini-backup rclone key/password" --account "$tb_acc" 2>/dev/null) || true
                    tb_cpw=$(op read "op://Personal/Tigris mini-backup rclone crypt/password" --account "$tb_acc" 2>/dev/null) || true
                    tb_csalt=$(op read "op://Personal/Tigris mini-backup rclone crypt/salt" --account "$tb_acc" 2>/dev/null) || true
                    tb_hc=$(op read "op://Personal/Tigris mini-backup rclone key/healthcheck_url" --account "$tb_acc" 2>/dev/null) || true
                    [[ -n "$tb_keyid"  ]] && security add-generic-password -a "$USER" -s "tigris-backup:s3-key-id"      -T /usr/bin/security -U -w "$tb_keyid"  2>/dev/null && tb_n=$((tb_n+1)) || true
                    [[ -n "$tb_keysec" ]] && security add-generic-password -a "$USER" -s "tigris-backup:s3-secret"      -T /usr/bin/security -U -w "$tb_keysec" 2>/dev/null && tb_n=$((tb_n+1)) || true
                    [[ -n "$tb_cpw"    ]] && security add-generic-password -a "$USER" -s "tigris-backup:crypt-password" -T /usr/bin/security -U -w "$tb_cpw"    2>/dev/null && tb_n=$((tb_n+1)) || true
                    [[ -n "$tb_csalt"  ]] && security add-generic-password -a "$USER" -s "tigris-backup:crypt-salt"     -T /usr/bin/security -U -w "$tb_csalt"  2>/dev/null && tb_n=$((tb_n+1)) || true
                    [[ -n "$tb_hc"     ]] && security add-generic-password -a "$USER" -s "tigris-backup:healthcheck-url" -T /usr/bin/security -U -w "$tb_hc"    2>/dev/null && tb_n=$((tb_n+1)) || true
                    [[ "$tb_n" -gt 0 ]] && echo "  [+] tigris-backup creds → Keychain ($tb_n/5)"
                    # sync-repos dead-man's-switch ping URL (mini-only heartbeat)
                    local sr_hc
                    sr_hc=$(op read "op://Personal/sync-repos-healthcheck/password" --account "$tb_acc" 2>/dev/null) || true
                    [[ -n "$sr_hc" ]] && security add-generic-password -a "$USER" -s "sync-repos:healthcheck-url" -T /usr/bin/security -U -w "$sr_hc" 2>/dev/null \
                        && echo "  [+] sync-repos healthcheck → Keychain" || true
                fi
            else
                echo "  Skipping GitHub MCP servers (1Password not configured)"
            fi
        fi
    fi

    # --- Codex ---
    if command -v codex >/dev/null 2>&1; then
        # Remove legacy server names from previous install.sh versions only.
        # Don't remove currently-managed servers — codex eagerly opens an OAuth
        # browser flow at 'mcp add' time, so we skip add when already present.
        # Trade-off: changing a server URL in install.sh requires manually
        # `codex mcp remove <name>` first; not auto-detected here.
        for legacy in dlt github-home github-work; do
            codex mcp remove "$legacy" >/dev/null 2>&1 || true
        done

        # OAuth servers — mirror of Claude Code's set. Add only if missing.
        # codex mcp add eagerly opens a browser OAuth flow and blocks on the
        # callback, so only run where there's a local browser to complete it.
        # A remote VM has a TTY (IS_INTERACTIVE=true) but no browser — running
        # this over SSH hangs forever — so gate on macOS, not just a TTY.
        # Linux VMs defer Codex MCP (like the Codex GitHub servers below).
        if [[ "$IS_INTERACTIVE" == true && "$OS" == "macos" ]]; then
            for srv in "motherduck https://api.motherduck.com/mcp" \
                       "tigris https://mcp.storage.dev/mcp" \
                       "readwise https://mcp2.readwise.io/mcp"; do
                read -r name url <<< "$srv"
                if codex mcp get "$name" >/dev/null 2>&1; then
                    echo "  [=] codex mcp: $name (already present)"
                else
                    codex mcp add "$name" --url "$url" >/dev/null 2>&1 \
                        && echo "  [+] codex mcp: $name" \
                        || echo "  [!] codex mcp add $name failed"
                fi
            done
        else
            echo "  Skipping Codex MCP servers (OAuth needs a local browser)"
        fi

        # personal-mcp local hub — no OAuth, so no browser needed (add even headless).
        if [[ -n "$hub_url" ]] && ! codex mcp get hub-mcp >/dev/null 2>&1; then
            codex mcp add hub-mcp --url "$hub_url" >/dev/null 2>&1 \
                && echo "  [+] codex mcp: hub-mcp" || true
        fi

        # GitHub MCP servers deferred. Codex disallows inline bearer tokens
        # (only --bearer-token-env-var), so wiring github-home/github-work
        # needs a codex wrapper that sources PATs via 'op run' at exec time.
        # See TODO.md "Secrets on remote VMs".
    fi

    echo "  [+] MCP servers configured"

    # gh CLI auth (separate from MCP PATs).
    # Interactive macOS prefers browser OAuth so gh gets its own scoped token
    # rather than reusing the MCP PAT. Headless/Linux falls back to the home
    # PAT from 1Password via --with-token.
    if command -v gh >/dev/null 2>&1; then
        if gh auth status >/dev/null 2>&1; then
            echo "  [=] gh already authenticated"
        elif [[ "$IS_INTERACTIVE" == true && "$OS" == "macos" ]]; then
            echo "  Authenticating gh CLI (browser OAuth)..."
            gh auth login --hostname github.com --git-protocol ssh --web \
                && echo "  [+] gh CLI auth'd via browser" \
                || echo "  [!] gh auth login --web failed"
        elif [[ "$op_configured" == true ]]; then
            local pat_home_gh
            pat_home_gh=$(op read "op://Private/GitHub PAT Home/token" --account lundstedts.1password.com 2>/dev/null) || true
            if [[ -n "$pat_home_gh" ]]; then
                printf '%s\n' "$pat_home_gh" | gh auth login --hostname github.com --with-token \
                    && echo "  [+] gh CLI auth'd with home PAT" \
                    || echo "  [!] gh auth login --with-token failed"
            else
                echo "  [!] gh auth: home PAT not available from 1Password"
            fi
        else
            echo "  [!] gh CLI not authenticated (no interactive shell, no 1Password)"
        fi
    fi

    # Skills
    if command -v npx >/dev/null 2>&1; then
        echo "  Installing agent skills..."
        # Skills baked into iv-image — only install on macOS (Linux VMs get them from the image)
        if [[ "$OS" == "macos" ]]; then
            npx -y skills add -g -y matsonj/mviz >/dev/null 2>&1 || true
            npx -y skills add -g -y vercel-labs/skills -s find-skills >/dev/null 2>&1 || true
            npx -y skills add -g -y duckdb/duckdb-skills >/dev/null 2>&1 || true
            npx -y skills add -g -y motherduckdb/agent-skills >/dev/null 2>&1 || true
            npx -y skills add -g -y posit-dev/skills -s quarto-authoring brand-yml >/dev/null 2>&1 || true
            npx -y skills add -g -y marimo-team/skills -s marimo-notebook marimo-batch >/dev/null 2>&1 || true
            # archil-guide — no GitHub repo, download skill file directly
            mkdir -p "$HOME/.agents/skills/archil-guide"
            curl -fsSL https://archil.com/skill.md -o "$HOME/.agents/skills/archil-guide/SKILL.md" 2>/dev/null || true
            for agent_dir in "$HOME/.claude/skills" "$HOME/.codex/skills"; do
                [ -d "$agent_dir" ] && ln -sf "../../.agents/skills/archil-guide" "$agent_dir/archil-guide" 2>/dev/null || true
            done
        fi
        # Personal skills (not in iv-image)
        npx -y skills add -g -y tigrisdata/tigris-agents-plugins >/dev/null 2>&1 || true
        npx -y skills add -g -y marimo-team/marimo-pair >/dev/null 2>&1 || true
        npx -y skills add -g -y kylelundstedt/dotfiles -s sprites-dev >/dev/null 2>&1 || true
        # apple-containers is private — installed locally on macOS only (npx -y skills add -g -y . -s apple-containers)
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

            # Start tailscaled as a system daemon (needs root for real tun device).
            # `tailscale status` probes via the UNIX socket and works regardless of
            # process ownership; pgrep alone misses root-owned tailscaled from a
            # non-root SSH session on macOS due to TCC process-visibility limits.
            if ! tailscale status >/dev/null 2>&1 && ! pgrep -x tailscaled >/dev/null 2>&1; then
                if sudo -n true 2>/dev/null; then
                    sudo brew services start tailscale 2>/dev/null || true
                    sleep 2
                    echo "  [+] tailscaled started via brew services"
                else
                    echo "  [!] tailscaled not running. Run: sudo brew services start tailscale"
                fi
            else
                # tailscaled is running — check for CLI/daemon version skew (occurs when
                # `brew upgrade` updates the formula but doesn't restart the service).
                local cli_ver daemon_ver
                cli_ver=$(tailscale version 2>/dev/null | head -1)
                daemon_ver=$(tailscale status --json 2>/dev/null | jq -r '.Version // empty' | sed 's/-t.*//')
                if [[ -n "$cli_ver" && -n "$daemon_ver" && "$cli_ver" != "$daemon_ver" ]]; then
                    if sudo -n true 2>/dev/null; then
                        echo "  Version skew (cli=$cli_ver daemon=$daemon_ver), restarting tailscaled..."
                        sudo brew services restart tailscale 2>/dev/null && sleep 2
                        echo "  [+] tailscaled restarted"
                    else
                        echo "  [!] Version skew (cli=$cli_ver daemon=$daemon_ver). Run: sudo brew services restart tailscale"
                    fi
                fi
            fi

            # Authenticate with SSH enabled
            if sudo -n true 2>/dev/null; then
                local ts_key="${TS_AUTHKEY:-}"
                if [[ -z "$ts_key" ]] && command -v op >/dev/null 2>&1; then
                    ts_key=$(op read "op://Employee/Tailscale - iv-internal-dev/credential" --account industryvault.1password.com 2>/dev/null) || true
                fi

                if [[ -n "$ts_key" ]]; then
                    sudo tailscale up --ssh --accept-dns --authkey="$ts_key" 2>/dev/null && echo "  [+] Tailscale up (SSH enabled)" || echo "  [!] tailscale up failed"
                elif tailscale status >/dev/null 2>&1; then
                    echo "  Already authenticated"
                    sudo tailscale set --ssh --accept-dns 2>/dev/null || true
                else
                    echo "  No auth key found. Run: sudo tailscale up --ssh"
                fi
            elif tailscale status >/dev/null 2>&1; then
                echo "  Already authenticated"
            else
                echo "  [!] sudo required. Run interactively: sudo tailscale up --ssh"
            fi
            # Open-source tailscaled doesn't configure macOS split DNS automatically.
            # Add /etc/resolver/ts.net so MagicDNS short names resolve.
            if [[ ! -f /etc/resolver/ts.net ]] && tailscale status --json >/dev/null 2>&1; then
                local ts_suffix
                ts_suffix=$(tailscale status --json 2>/dev/null | jq -r '.MagicDNSSuffix // empty')
                if [[ -n "$ts_suffix" ]]; then
                    if sudo -n true 2>/dev/null; then
                        sudo mkdir -p /etc/resolver
                        printf 'nameserver 100.100.100.100\nsearch %s\n' "$ts_suffix" | sudo tee /etc/resolver/ts.net >/dev/null
                        echo "  [+] MagicDNS resolver (/etc/resolver/ts.net)"
                    else
                        echo "  [!] MagicDNS resolver missing. Run: sudo mkdir -p /etc/resolver && printf 'nameserver 100.100.100.100\\nsearch $ts_suffix\\n' | sudo tee /etc/resolver/ts.net"
                    fi
                fi
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

    # Default TS_HOSTNAME to the system hostname so the Tailscale name
    # always matches the VM name (exe.dev sets hostname to the VM name).
    : "${TS_HOSTNAME:=$(hostname)}"

    # If Tailscale is already connected, just ensure SSH+DNS flags and
    # set up the cron entry.
    if tailscale status >/dev/null 2>&1; then
        echo "  Already connected"
        $SUDO tailscale set --ssh --accept-dns --accept-routes 2>/dev/null || true
    else
        # Install if missing
        if ! command -v tailscale >/dev/null 2>&1; then
            echo "  Installing Tailscale..."
            curl -fsSL https://tailscale.com/install.sh | sh >/dev/null 2>&1 || { echo "  [!] Tailscale install failed"; return 0; }
            echo "  [+] Tailscale"
        fi

        # Prefer kernel mode (real tailscale0 interface, working MagicDNS, plain ssh
        # to peers) when /dev/net/tun is available. Fall back to userspace mode for
        # platforms that don't expose TUN (Sprite, some Apple Containers configs).
        local ts_args=""
        [ -c /dev/net/tun ] || ts_args="--tun=userspace-networking"

        # Start tailscaled if not running
        if ! pgrep -x tailscaled >/dev/null 2>&1; then
            if [ -d "/.sprite" ] && command -v sprite-env >/dev/null 2>&1; then
                # Sprite — register as a service so it survives sleep/wake (always userspace)
                sprite-env services create tailscaled --cmd /usr/sbin/tailscaled --args "--tun=userspace-networking" --no-stream 2>/dev/null || true
                sleep 2
            elif [ -d /run/systemd/system ]; then
                # systemd is the active init system (not just installed as a dep)
                $SUDO systemctl enable --now tailscaled 2>/dev/null || true
            else
                # No systemd, no Sprite (e.g. Apple Containers, exe.dev) — start directly
                $SUDO sh -c "nohup tailscaled $ts_args >/dev/null 2>&1 &"
                sleep 2
            fi
        fi

        # On exe.dev VMs, the tailscale-api integration proxy is reachable
        # and can generate auth keys without any secrets on disk. Use it
        # when TS_AUTHKEY wasn't provided explicitly.
        local ts_key="${TS_AUTHKEY:-}"
        if [[ -z "$ts_key" ]]; then
            local ts_proxy="https://tailscale-api.int.exe.xyz"
            if curl -sfo /dev/null --connect-timeout 2 "$ts_proxy/api/v2/tailnet/-/devices" 2>/dev/null; then
                echo "  exe.dev proxy reachable — generating auth key"
                # Clean stale nodes with same hostname (prevents -2 suffix)
                local did
                for did in $(curl -sL "$ts_proxy/api/v2/tailnet/-/devices" \
                    | jq -r --arg h "$TS_HOSTNAME" '.devices[] | select(.hostname == $h) | .id'); do
                    curl -sL -X DELETE "$ts_proxy/api/v2/device/$did" >/dev/null
                done
                # Generate single-use ephemeral auth key
                ts_key=$(curl -sL -X POST "$ts_proxy/api/v2/tailnet/-/keys" \
                    -H "Content-Type: application/json" \
                    -d '{"capabilities":{"devices":{"create":{"reusable":false,"ephemeral":true,"preauthorized":true,"tags":["tag:dev"]}}}}' \
                    | jq -r '.key')
            fi
        fi

        # Authenticate with --ssh if we have an auth key
        if [[ -n "$ts_key" ]]; then
            $SUDO tailscale up --ssh --accept-dns --accept-routes --authkey="$ts_key" --hostname "$TS_HOSTNAME" 2>/dev/null && echo "  [+] Tailscale up (SSH enabled, hostname=$TS_HOSTNAME)" || echo "  [!] tailscale up failed"
        else
            echo "  No auth key found. Run: sudo tailscale up --ssh"
        fi
    fi

    # Maintain @reboot cron entry on platforms without an init system.
    # Self-heals stale flags (e.g. a previous install used userspace mode).
    if ! [ -d "/.sprite" ] && ! [ -d /run/systemd/system ]; then
        local ts_args_cron=""
        [ -c /dev/net/tun ] || ts_args_cron="--tun=userspace-networking"
        local cron_cmd
        if [[ -n "$ts_args_cron" ]]; then
            cron_cmd="@reboot nohup tailscaled $ts_args_cron >/dev/null 2>&1 &"
        else
            cron_cmd="@reboot nohup tailscaled >/dev/null 2>&1 &"
        fi
        local current_cron
        current_cron=$($SUDO crontab -l 2>/dev/null || true)
        if ! printf '%s\n' "$current_cron" | grep -qxF "$cron_cmd"; then
            { printf '%s\n' "$current_cron" | grep -v 'tailscaled' | grep -v '^$' || true; echo "$cron_cmd"; } | $SUDO crontab -
        fi
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

    # Several casks are pkg-based installers (Microsoft suite, Zoom, ...) and the
    # Apple Container pkg below also needs root. Prime sudo once and keep the
    # timestamp warm in the background so you enter your password a single time
    # instead of once per installer. Interactive only — never relax sudo headless.
    local sudo_keepalive_pid=""
    if [[ "$IS_INTERACTIVE" == true ]] && sudo -v 2>/dev/null; then
        ( while kill -0 "$$" 2>/dev/null; do sudo -n true 2>/dev/null || true; sleep 50; done ) &
        sudo_keepalive_pid=$!
        echo "  [+] sudo primed (one prompt covers all pkg installers)"
    fi

    # Trust the non-official taps referenced in the Brewfile so `brew bundle` can
    # load their casks when HOMEBREW_REQUIRE_TAP_TRUST is set. Idempotent — writes
    # ~/.homebrew/trust.json. Without this, dbc/flux-markdown are refused.
    brew trust columnar-tech/tap >/dev/null 2>&1 || true   # dbc
    brew trust xykong/tap >/dev/null 2>&1 || true          # flux-markdown

    brew bundle --file="$DOTFILES_DIR/homebrew/Brewfile" || echo "  Note: some casks/mas apps may have failed (normal)."

    # LM Studio ships the `lms` CLI inside the app bundle. Its own `lms bootstrap`
    # edits shell rc files (which this repo manages via stow), so instead symlink
    # the shim into ~/.local/bin — same pattern as node/quarto above. The shim at
    # ~/.lmstudio/bin/lms is created the first time LM Studio launches, so this is
    # a no-op (with a hint) until then; re-running install.sh wires it up.
    if [[ -x "$HOME/.lmstudio/bin/lms" ]]; then
        ln -sf "$HOME/.lmstudio/bin/lms" "$LOCAL_BIN/lms"
        echo "  [+] lms CLI (symlinked from ~/.lmstudio/bin)"
    elif ls -d "/Applications/LM Studio.app" &>/dev/null; then
        echo "  [=] lms CLI: launch LM Studio once to create ~/.lmstudio/bin/lms, then re-run install.sh"
    fi

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

    # Stop the sudo keepalive started for the pkg-based installers above.
    [[ -n "${sudo_keepalive_pid:-}" ]] && kill "$sudo_keepalive_pid" 2>/dev/null || true
}

# Load stowed LaunchAgents (macOS). Runs on every macOS install, not just
# --apps, so scheduled jobs (sync-repos, msgvault-sync, etc.) are active
# immediately rather than only after the next login.
load_launch_agents() {
    [[ "$OS" == "macos" ]] || return 0
    [[ "$DRY_RUN" == true ]] && return 0
    echo ""
    echo "=== LaunchAgents ==="
    shopt -s nullglob
    for plist in "$HOME/Library/LaunchAgents"/com.kylelundstedt.*.plist; do
        # bootout first so an updated plist is reloaded idempotently
        launchctl bootout "gui/$(id -u)" "$plist" 2>/dev/null || true
        if launchctl bootstrap "gui/$(id -u)" "$plist" 2>/dev/null; then
            echo "  loaded $(basename "$plist")"
        else
            # fall back to legacy load for older macOS
            launchctl load -w "$plist" 2>/dev/null && echo "  loaded $(basename "$plist")" || echo "  WARN: failed to load $(basename "$plist")"
        fi
    done
    shopt -u nullglob
}

# --- Main ---
cd "$DOTFILES_DIR" || { echo "Error: $DOTFILES_DIR not found"; exit 1; }

echo "Install: OS=$OS, apps=$INSTALL_APPS, dry-run=$DRY_RUN, upgrade=$UPGRADE"
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
load_launch_agents

# Ensure Apple Container kernel is installed and system is running
if command -v container >/dev/null 2>&1; then
    echo ""
    echo "=== Apple Container System ==="
    container system kernel set --recommended 2>/dev/null && echo "  [+] Kernel set to recommended" || true
    container system start </dev/null 2>/dev/null || true
fi

echo ""
echo "Done. Start a new shell session (or run: exec zsh)"

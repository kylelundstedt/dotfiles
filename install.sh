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
#
# IV-provisioned exe.dev VM (U7, Core decision 1): iv-image's provision-iv.sh
# owns the team baseline there — pinned tools, team AGENTS.md, team MCP
# servers, its ssh stanza — and install.sh behaves as a thin personal overlay:
# personal delta only, never redo or clobber what the image laid down. A bare
# exe.dev VM without the IV layer still gets the full personal install.
# (Provision iv-image BEFORE dotfiles on VMs that want both.)
IS_IV_VM=false
[[ -d /exe.dev && -f "$HOME/iv-provision.lock" ]] && IS_IV_VM=true

# want() also refuses team-layer tools (tools.manifest) on IV VMs: those are
# iv-image's, version-pinned — installing (or --upgrade'ing) the floating
# dotfiles copy would shadow the pin.
want() {
    if [[ "$IS_IV_VM" == true ]] && grep -qE "^team[[:space:]]+$1[[:space:]]*$" "$DOTFILES_DIR/provisioning/tools.manifest" 2>/dev/null; then
        return 1
    fi
    need "$1" || [[ "$UPGRADE" == true ]]
}

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
    # `|| true`: with no match (e.g. rate-limited response) the grep pipeline
    # fails, and under set -euo pipefail the failed assignment would abort the
    # whole script before the empty-check below can report why.
    asset_url=$(echo "$api_response" \
        | grep -oE "\"browser_download_url\": \"[^\"]+\"" \
        | grep -E "$pattern" \
        | head -1 \
        | sed 's/"browser_download_url": "//;s/"//' || true)
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
    version=$(echo "$resp" | grep -oE '"tag_name": "v[^"]+"' | head -1 | sed 's/.*"v\([^"]*\)".*/\1/' || true)
    [[ -z "$version" ]] && { echo "  [!] quarto: no version in release"; return 1; }
    url=$(echo "$resp" \
        | grep -oE "\"browser_download_url\": \"[^\"]+\"" \
        | grep -F "quarto-${version}-${quarto_arch}.tar.gz" \
        | head -1 \
        | sed 's/"browser_download_url": "//;s/"//' || true)
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
    # herdr assets are bare version-less binaries: herdr-{macos,linux}-{aarch64,x86_64}
    local herdr_asset
    case "$OS-$arch" in
        macos-arm64)   herdr_asset="herdr-macos-aarch64" ;;
        macos-x86_64)  herdr_asset="herdr-macos-x86_64" ;;
        linux-aarch64) herdr_asset="herdr-linux-aarch64" ;;
        linux-x86_64)  herdr_asset="herdr-linux-x86_64" ;;
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
    if want herdr; then
        (install_release_asset "ogulcancelik/herdr" "$herdr_asset" "herdr" "$herdr_asset") &
        pids+=($!)
    else echo "  [=] herdr"; fi
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
        # The personal stanzas live in a marker-managed block PREPENDED to the
        # file (U7 — no truncating writes): iv-image's provision-iv.sh appends
        # its own `iv-provision` block, which must survive re-runs of either
        # provisioner. Prepending also keeps CanonicalizeHostname BEFORE all
        # Host blocks — OpenSSH's "first obtained value" rule means Host
        # blocks otherwise get evaluated against the short name, before
        # canonicalization can rewrite it. Verified empirically: with these
        # lines mid-file, `ssh gitlake` from another VM falls through to
        # default StrictHostKeyChecking and fails on host-key change.
        local block_file rest_file
        block_file=$(mktemp); rest_file=$(mktemp)
        {
            echo "# >>> dotfiles ssh >>>"
            echo "# Managed by dotfiles/install.sh — edit the repo, not this block."
            if [[ -n "$tailnet_domain" ]]; then
                cat <<SSHEOF

CanonicalizeHostname yes
CanonicalDomains $tailnet_domain
CanonicalizeMaxDots 0
SSHEOF
            fi
            cat <<SSHEOF

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
# <<< dotfiles ssh <<<
SSHEOF
        } > "$block_file"
        # Foreign content to preserve: everything outside our marker block.
        # Migration: files written by the pre-U7 truncating version ("do not
        # edit manually" header, no markers) were wholly ours EXCEPT an
        # iv-provision block appended after the fact — keep only that.
        if [[ -f "$ssh_config" ]]; then
            if grep -q '^# >>> dotfiles ssh >>>' "$ssh_config"; then
                awk '/^# >>> dotfiles ssh >>>/{f=1;next} /^# <<< dotfiles ssh <<</{f=0;next} !f' "$ssh_config" > "$rest_file"
            elif head -1 "$ssh_config" | grep -q '^# Managed by dotfiles/install.sh'; then
                awk '/^# >>> iv-provision ssh >>>/{f=1} f; /^# <<< iv-provision ssh <<</{f=0}' "$ssh_config" > "$rest_file"
            else
                cat "$ssh_config" > "$rest_file"
            fi
        fi
        cat "$block_file" "$rest_file" > "$ssh_config"
        rm -f "$block_file" "$rest_file"
        echo "  [+] SSH config (Linux — dotfiles block prepended, foreign blocks preserved)"

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

# --- overlay_agents_delta ---
# IV VMs only (U7): layer the personal AGENTS.md delta onto iv-image's team
# file instead of replacing it. The personal file's shared block (embedded
# from provisioning/agents-shared.md) is already IN the team file at the
# image's pin, so the delta = the personal file minus that block, minus the
# standalone header/preamble. Marker-managed — idempotent across re-runs of
# either provisioner.
overlay_agents_delta() {
    [[ "$IS_IV_VM" == true ]] || return 0
    local team="$HOME/.agents/AGENTS.md" src="$DOTFILES_DIR/agents/.agents/AGENTS.md"
    if [[ ! -f "$team" ]]; then
        echo "  [!] team AGENTS.md missing — skipping personal overlay"
        return 0
    fi
    local delta existing
    delta=$(awk '/^<!-- >>> shared/{sh=1;next} /^<!-- <<< shared/{sh=0;next} sh{next} /^## /{started=1} started' "$src")
    # $(…) strips trailing newlines, so re-runs can't accumulate blank lines
    existing=$(awk '/^<!-- >>> personal overlay >>>/{f=1;next} /^<!-- <<< personal overlay <<</{f=0;next} !f' "$team")
    {
        printf '%s\n\n' "$existing"
        echo "<!-- >>> personal overlay >>> (dotfiles agents/.agents/AGENTS.md minus its shared block — managed by install.sh) -->"
        echo ""
        printf '%s\n' "$delta"
        echo "<!-- <<< personal overlay <<< -->"
    } > "$team"
    echo "  [+] personal AGENTS.md delta layered onto the team file"
}

# --- overlay_claude_settings ---
# IV VMs only (U7): iv-image owns ~/.claude/settings.json (team defaults +
# the exe.dev SSH guard). Splice ONLY the personal SessionStart hook into it
# (the auto ~/dotfiles refresh on session start) — without it the overlay
# would cost VMs the dotfiles auto-pull. Idempotent, keyed on the script path.
overlay_claude_settings() {
    [[ "$IS_IV_VM" == true ]] || return 0
    local f="$HOME/.claude/settings.json"
    [[ -f "$f" ]] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    grep -q "refresh-env.sh" "$f" && return 0
    jq '.hooks.SessionStart = ((.hooks.SessionStart // []) + [{"hooks":[{"type":"command","command":"\"$HOME/.agents/refresh-env.sh\"","timeout":20}]}])' \
        "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    echo "  [+] SessionStart refresh-env hook spliced into team settings.json"
}

# --- sync_claude_settings_hooks ---
# The live agents/.claude/settings.json is gitignored (Claude Code mutates it
# at runtime) and was seeded from the example only when ABSENT — so hooks
# added to the example later never reached existing installs (bit us with the
# SSH guard, 2026-07-13). Splice each known hook from the example if missing;
# the example stays the single source. Not on IV VMs (iv-image owns
# ~/.claude/settings.json there; overlay_claude_settings handles that path).
# INVARIANT: call this only from run_stow, BEFORE the stow step — a spliced
# hook may reference a stow-deployed script (refresh-env.sh does), so the
# splice must never run on a path where stowing doesn't follow it.
sync_claude_settings_hooks() {
    [[ "$IS_IV_VM" == true ]] && return 0
    local f="$DOTFILES_DIR/agents/.claude/settings.json"
    local ex="$DOTFILES_DIR/agents/.claude/settings.json.example"
    [[ -f "$f" && -f "$ex" ]] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    if ! grep -q "refresh-env.sh" "$f"; then
        jq --slurpfile ex "$ex" '.hooks.SessionStart = ((.hooks.SessionStart // []) + $ex[0].hooks.SessionStart)' "$f" > "$f.tmp" \
            && mv "$f.tmp" "$f" && echo "  [+] settings.json: SessionStart hook synced from example"
    fi
    if ! grep -q "exe.dev SSH guard" "$f"; then
        jq --slurpfile ex "$ex" '.hooks.PreToolUse = ((.hooks.PreToolUse // []) + $ex[0].hooks.PreToolUse)' "$f" > "$f.tmp" \
            && mv "$f.tmp" "$f" && echo "  [+] settings.json: PreToolUse SSH guard synced from example"
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
    # Seed it from the example so stow has something to link — except on IV VMs,
    # where iv-image owns ~/.claude/settings.json (team defaults + SSH guard) and
    # the personal SessionStart hook is spliced in by overlay_claude_settings.
    local claude_settings="$DOTFILES_DIR/agents/.claude/settings.json"
    if [[ "$IS_IV_VM" != true && ! -f "$claude_settings" && -f "${claude_settings}.example" ]]; then
        cp "${claude_settings}.example" "$claude_settings"
        echo "  Seeded agents/.claude/settings.json from example"
    fi
    sync_claude_settings_hooks

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
    # NOT on IV VMs (U7): there, the team agent config (iv-image) stays in
    # place — the agents package is stowed around it and the personal
    # AGENTS.md delta is layered in by overlay_agents_delta below.
    if [[ "$IS_IV_VM" != true ]]; then
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
    fi

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
        # IV VMs: stow the agents package AROUND the team agent files —
        # iv-image owns ~/.agents/AGENTS.md and the CLAUDE.md/AGENTS.md
        # symlinks there; the personal delta is layered in afterwards.
        local -a stow_extra=()
        if [[ "$IS_IV_VM" == true && "$folder" == "agents" ]]; then
            # settings\.json is anchored at end by stow, so the .example
            # still stows; a settings.json left by a pre-U7 run must not
            # conflict with iv-image's real file.
            stow_extra=(--ignore='AGENTS\.md' --ignore='CLAUDE\.md' --ignore='settings\.json')
        fi
        if [[ "$DRY_RUN" == true ]]; then
            stow --no-folding -R -n -t "$HOME" "${stow_extra[@]+"${stow_extra[@]}"}" "$folder"
        elif [[ "$OS" == "macos" || "$IS_INTERACTIVE" == true ]]; then
            stow --adopt --no-folding -R -t "$HOME" "${stow_extra[@]+"${stow_extra[@]}"}" "$folder"
        else
            stow --no-folding -R -t "$HOME" "${stow_extra[@]+"${stow_extra[@]}"}" "$folder"
        fi
    done

    overlay_agents_delta
    overlay_claude_settings

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
# --- provisioning manifest helpers ---
# The skill/MCP sets are declared in provisioning/*.manifest (single source of
# truth shared with iv-image — see agent_docs/simplification-plan.md, decision 3).
# Manifest read-loops feed on fd 9 (read -u 9 ... done 9<<< "$(...)"), NOT
# stdin: child commands (npx/claude/codex/op) read stdin and silently eat the
# remaining rows otherwise. Here-strings, NOT process substitution <(...) —
# exe.dev's bare ubuntu:24.04 image has no /dev/fd symlink, so every bash
# procsub there dies with "/dev/fd/63: No such file or directory" (2026-07-14).
# Caveat: an empty command substitution still yields ONE empty read, so every
# loop body must skip blank first fields.
manifest_rows() { grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$1"; }
# Trim leading/trailing whitespace from a pipe-manifest field.
mtrim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

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
                # || true: install_github_binary prints its own [!] on failure;
                # unguarded, its non-zero return would abort the script (set -e).
                install_github_binary "openai/codex" \
                    "codex-${codex_arch}-unknown-linux-musl\\.tar\\.gz" \
                    "codex" \
                    "codex-${codex_arch}-unknown-linux-musl" || true
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

    # Declared HERE, not inside the Claude block: the Codex block below also
    # reads it, and under set -u a codex-only machine (Claude install failed)
    # would otherwise die on an unbound variable.
    local mcp_manifest="$DOTFILES_DIR/provisioning/mcp.manifest"

    # --- Claude Code ---
    if command -v claude >/dev/null 2>&1; then
        # On IV VMs the team-layer servers (mcp.manifest) are seeded by
        # iv-image's setup-mcp.sh — the overlay must neither remove nor
        # re-add them (U7).
        local team_mcp=""
        if [[ "$IS_IV_VM" == true && -f "$mcp_manifest" ]]; then
            team_mcp=$(manifest_rows "$mcp_manifest" | awk -F'|' '$2 ~ /team/ {gsub(/ /,"",$1); print $1}')
        fi
        # Remove stale or migrated servers before re-adding with correct URLs.
        # On Linux, motherduck migrates from OAuth to exe.dev proxy.
        for srv in dlt motherduck github-home github-work tigris readwise hub-mcp; do
            [[ -n "$team_mcp" ]] && grep -qx "$srv" <<<"$team_mcp" && continue
            claude mcp remove --scope user "$srv" >/dev/null 2>&1 || true
        done

        # The server set + URLs come from provisioning/mcp.manifest
        # (name|layer|vm-url|mac). On VMs the vm-url column is an exe.dev HTTP
        # proxy integration (static tokens; no secrets on VM disk) or a direct
        # OAuth endpoint — OAuth-only servers (Tigris, Readwise) need a one-time
        # browser dance over an explicit `ssh -L 8765:localhost:8765 <vm>.exe.xyz`
        # tunnel (not always-on). On macOS the mac column is a direct URL, or
        # pat:<1p-account>:<op-ref> = the GitHub Copilot MCP endpoint with a
        # Bearer PAT read from 1Password at install time.
        # Counters count SUCCESSES; every failure gets a visible [!] line —
        # a fresh machine must not finish looking configured while agent
        # capabilities silently failed (2026-07-13 review, same class as the
        # sync-repos listing bug).
        local m_name m_layer m_vm m_mac m_acct m_opref m_tok m_n=0 m_fail=0
        if [[ ! -f "$mcp_manifest" ]]; then
            echo "  [!] $mcp_manifest missing — skipping MCP registration"
        elif [[ "$OS" == "linux" ]]; then
            while IFS='|' read -u 9 -r m_name m_layer m_vm m_mac; do
                m_name=$(mtrim "$m_name"); m_layer=$(mtrim "$m_layer"); m_vm=$(mtrim "$m_vm")
                [[ -z "$m_name" || -z "$m_vm" || "$m_vm" == "-" ]] && continue
                # IV VMs: team rows already seeded by iv-image — personal only
                [[ "$IS_IV_VM" == true && "$m_layer" == "team" ]] && continue
                if claude mcp add --transport http --scope user "$m_name" "$m_vm" >/dev/null 2>&1; then
                    m_n=$((m_n+1))
                else
                    echo "  [!] claude mcp add $m_name failed"; m_fail=$((m_fail+1))
                fi
            done 9<<< "$(manifest_rows "$mcp_manifest")"
            if [[ "$IS_IV_VM" == true ]]; then
                echo "  [+] MCP servers ($m_n personal rows registered, $m_fail failed; team rows left to iv-image)"
            else
                echo "  [+] MCP servers ($m_n registered from mcp.manifest, $m_fail failed)"
            fi
        else
            # macOS: direct/OAuth URLs; pat: rows need 1Password
            while IFS='|' read -u 9 -r m_name m_layer m_vm m_mac; do
                m_name=$(mtrim "$m_name"); m_mac=$(mtrim "$m_mac")
                [[ -z "$m_name" || -z "$m_mac" ]] && continue
                if [[ "$m_mac" == pat:* ]]; then
                    if [[ "$op_configured" != true ]]; then
                        echo "  Skipping $m_name (1Password not configured)"
                        continue
                    fi
                    m_acct="${m_mac#pat:}"; m_acct="${m_acct%%:*}"
                    m_opref="${m_mac#pat:*:}"
                    m_tok=$(op read "$m_opref" --account "$m_acct" 2>/dev/null) || true
                    if [[ -z "$m_tok" ]]; then
                        echo "  [!] $m_name: 1Password read failed/empty ($m_opref)"; m_fail=$((m_fail+1))
                    elif claude mcp add-json --scope user "$m_name" \
                        "{\"type\":\"http\",\"url\":\"https://api.githubcopilot.com/mcp/\",\"headers\":{\"Authorization\":\"Bearer $m_tok\"}}" >/dev/null 2>&1; then
                        m_n=$((m_n+1))
                    else
                        echo "  [!] claude mcp add-json $m_name failed"; m_fail=$((m_fail+1))
                    fi
                else
                    if claude mcp add --transport http --scope user "$m_name" "$m_mac" >/dev/null 2>&1; then
                        m_n=$((m_n+1))
                    else
                        echo "  [!] claude mcp add $m_name failed"; m_fail=$((m_fail+1))
                    fi
                fi
            done 9<<< "$(manifest_rows "$mcp_manifest")"
            echo "  [+] MCP servers ($m_n registered from mcp.manifest, $m_fail failed)"
            if [[ -n "$hub_url" ]]; then
                claude mcp add --transport http --scope user hub-mcp "$hub_url" >/dev/null 2>&1 \
                    && echo "  [+] hub-mcp ($hub_url)" \
                    || echo "  [!] claude mcp add hub-mcp failed ($hub_url)"
            fi
            if [[ "$op_configured" == true ]]; then
                local pat_work
                pat_work=$(op read "op://Employee/GitHub PAT IV/token" --account industryvault.1password.com 2>/dev/null) || true

                # sync-repos.sh reads per-org GitHub PATs from the local login
                # Keychain (fine-grained PATs are scoped per owner; gh's Home
                # token can't list IndustryVault/iv-cmg). Provision them from
                # 1Password so the nightly repo sync works on every Mac. The
                # Keychain is local per-machine, so this runs on each install.
                # pat_work is the IV token (reused); -T allows the `security`
                # tool to read it back non-interactively from the launchd job.
                local pat_ivcmg kc_added=0
                pat_ivcmg=$(op read "op://Employee/GitHub PAT IV-CMG/token" --account industryvault.1password.com 2>/dev/null) || true
                if [[ -n "$pat_work" ]]; then
                    security add-generic-password -a "$USER" -s "sync-repos:IndustryVault" -T /usr/bin/security -U -w "$pat_work" 2>/dev/null && kc_added=$((kc_added+1)) \
                        || echo "  [!] Keychain write failed: sync-repos:IndustryVault"
                else
                    echo "  [!] 1Password read failed/empty: GitHub PAT IV (sync-repos:IndustryVault not provisioned)"
                fi
                if [[ -n "$pat_ivcmg" ]]; then
                    security add-generic-password -a "$USER" -s "sync-repos:iv-cmg" -T /usr/bin/security -U -w "$pat_ivcmg" 2>/dev/null && kc_added=$((kc_added+1)) \
                        || echo "  [!] Keychain write failed: sync-repos:iv-cmg"
                else
                    echo "  [!] 1Password read failed/empty: GitHub PAT IV-CMG (sync-repos:iv-cmg not provisioned)"
                fi
                [[ "$kc_added" -gt 0 ]] && echo "  [+] sync-repos org PATs → Keychain ($kc_added/2)"

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
                    if [[ "$tb_n" -eq 5 ]]; then
                        echo "  [+] tigris-backup creds → Keychain (5/5)"
                    else
                        echo "  [!] tigris-backup creds → Keychain incomplete ($tb_n/5 — check 1Password reads above)"
                    fi
                    # Encrypted external drive (OWC8TB) passphrase — used by
                    # owc8tb-unlock.sh to auto-mount the drive after a reboot so
                    # the nightly can read the archive sources + Photos library.
                    local owc_pw
                    owc_pw=$(op read "op://Personal/OWC8TB disk encryption/password" --account "$tb_acc" 2>/dev/null) || true
                    if [[ -n "$owc_pw" ]]; then
                        security add-generic-password -a "$USER" -s "owc8tb-encryption" -T /usr/bin/security -U -w "$owc_pw" 2>/dev/null \
                            && echo "  [+] OWC8TB disk passphrase → Keychain" \
                            || echo "  [!] Keychain write failed: owc8tb-encryption"
                    else
                        echo "  [!] 1Password read failed/empty: OWC8TB disk encryption"
                    fi
                    # sync-repos dead-man's-switch ping URL (mini-only heartbeat)
                    local sr_hc
                    sr_hc=$(op read "op://Personal/sync-repos-healthcheck/password" --account "$tb_acc" 2>/dev/null) || true
                    if [[ -n "$sr_hc" ]]; then
                        security add-generic-password -a "$USER" -s "sync-repos:healthcheck-url" -T /usr/bin/security -U -w "$sr_hc" 2>/dev/null \
                            && echo "  [+] sync-repos healthcheck → Keychain" \
                            || echo "  [!] Keychain write failed: sync-repos:healthcheck-url"
                    else
                        echo "  [!] 1Password read failed/empty: sync-repos-healthcheck"
                    fi
                fi
            else
                echo "  Skipping Keychain credential provisioning (1Password not configured)"
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

        # OAuth servers — mirror of Claude Code's set: the mcp.manifest rows
        # whose mac column is a direct URL (pat: rows are deferred, see below).
        # Add only if missing: codex mcp add eagerly opens a browser OAuth flow
        # and blocks on the callback, so only run where there's a local browser
        # to complete it. A remote VM has a TTY (IS_INTERACTIVE=true) but no
        # browser — running this over SSH hangs forever — so gate on macOS, not
        # just a TTY. Linux VMs defer Codex MCP (like the Codex GitHub servers below).
        if [[ "$IS_INTERACTIVE" == true && "$OS" == "macos" && -f "$mcp_manifest" ]]; then
            local c_name c_layer c_vm c_mac
            while IFS='|' read -u 9 -r c_name c_layer c_vm c_mac; do
                c_name=$(mtrim "$c_name"); c_mac=$(mtrim "$c_mac")
                [[ -z "$c_name" || -z "$c_mac" || "$c_mac" == pat:* ]] && continue
                if codex mcp get "$c_name" >/dev/null 2>&1; then
                    echo "  [=] codex mcp: $c_name (already present)"
                else
                    codex mcp add "$c_name" --url "$c_mac" >/dev/null 2>&1 \
                        && echo "  [+] codex mcp: $c_name" \
                        || echo "  [!] codex mcp add $c_name failed"
                fi
            done 9<<< "$(manifest_rows "$mcp_manifest")"
        else
            echo "  Skipping Codex MCP servers (OAuth needs a local browser)"
        fi

        # personal-mcp local hub — no OAuth, so no browser needed (add even headless).
        if [[ -n "$hub_url" ]] && ! codex mcp get hub-mcp >/dev/null 2>&1; then
            codex mcp add hub-mcp --url "$hub_url" >/dev/null 2>&1 \
                && echo "  [+] codex mcp: hub-mcp" \
                || echo "  [!] codex mcp add hub-mcp failed ($hub_url)"
        fi

        # GitHub MCP servers deferred. Codex disallows inline bearer tokens
        # (only --bearer-token-env-var), so wiring github-home/github-work
        # needs a codex wrapper that sources PATs via 'op run' at exec time.
        # See TODO.md "Secrets on remote VMs".
    fi

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

    # Skills — the set comes from provisioning/skills.manifest (layer method
    # args). Team skills are baked into iv-image, so they install on macOS only
    # (Linux VMs get them vendored from the image); personal skills install
    # everywhere. apple-containers is private — installed locally on macOS only
    # (npx -y skills add -g -y . -s apple-containers).
    local skills_manifest="$DOTFILES_DIR/provisioning/skills.manifest"
    if command -v npx >/dev/null 2>&1 && [[ -f "$skills_manifest" ]]; then
        echo "  Installing agent skills (skills.manifest)..."
        local s_layer s_method s_args s_name s_url s_ok=0 s_fail=0
        while read -u 9 -r s_layer s_method s_args; do
            [[ -z "$s_layer" ]] && continue
            [[ "$s_layer" == "team" && "$OS" != "macos" ]] && continue
            case "$s_method" in
                npx)
                    # $s_args is intentionally word-split (repo + optional -s flags)
                    # shellcheck disable=SC2086
                    if npx -y skills add -g -y $s_args >/dev/null 2>&1; then
                        s_ok=$((s_ok+1))
                    else
                        echo "  [!] skill install failed: npx skills add $s_args"; s_fail=$((s_fail+1))
                    fi
                    ;;
                curl)
                    # args = "<name> <url>" — no GitHub repo, download skill file directly
                    read -r s_name s_url <<< "$s_args"
                    mkdir -p "$HOME/.agents/skills/$s_name"
                    if curl -fsSL "$s_url" -o "$HOME/.agents/skills/$s_name/SKILL.md" 2>/dev/null; then
                        s_ok=$((s_ok+1))
                    else
                        echo "  [!] skill download failed: $s_name ($s_url)"; s_fail=$((s_fail+1))
                    fi
                    for agent_dir in "$HOME/.claude/skills" "$HOME/.codex/skills"; do
                        [ -d "$agent_dir" ] && ln -sf "../../.agents/skills/$s_name" "$agent_dir/$s_name" 2>/dev/null || true
                    done
                    ;;
                *)  echo "  [!] skills.manifest: unknown method '$s_method' for '$s_args'"; s_fail=$((s_fail+1)) ;;
            esac
        done 9<<< "$(manifest_rows "$skills_manifest")"
        echo "  [+] Skills ($s_ok installed, $s_fail failed)"
    else
        echo "  [!] npx or skills.manifest missing, skipping skill installation"
    fi

    if ! command -v op >/dev/null 2>&1; then
        echo ""
        echo "  Note: 1Password CLI is required at runtime for secret-backed MCP servers."
    fi

    # Session-start auto-refresh reminder (exe.dev VMs only). Each harness runs
    # ~/.agents/refresh-env.sh at session start to keep ~/dotfiles current (see
    # README "Session-start auto-refresh"). Codex gates hooks behind a one-time
    # interactive trust; Claude Code and Shelley need no approval.
    if [ -d /exe.dev ]; then
        echo ""
        echo "  Note: agents auto-refresh ~/dotfiles at session start via hooks."
        echo "        Codex needs a one-time trust per VM: run 'codex', then '/hooks'"
        echo "        and trust the SessionStart hook. (Claude Code + Shelley: no action.)"
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
                # klundstedt-mini is a TAGGED device (tag:dev, persistent) —
                # mint it a non-ephemeral tag:dev key via the Tailscale OAuth
                # client (U11; retired the static iv-internal-dev key). Other
                # Macs (mbp) are untagged user devices: TS_AUTHKEY env or the
                # one-time interactive browser flow below.
                local ts_key="${TS_AUTHKEY:-}"
                if [[ -z "$ts_key" && "$(scutil --get LocalHostName 2>/dev/null)" == "klundstedt-mini" ]] && command -v op >/dev/null 2>&1; then
                    local ts_cid ts_csec ts_token
                    ts_cid=$(op read "op://Employee/Tailscale OAuth Dev/Client ID" --account industryvault.1password.com 2>/dev/null) || true
                    ts_csec=$(op read "op://Employee/Tailscale OAuth Dev/Client secret" --account industryvault.1password.com 2>/dev/null) || true
                    if [[ -n "$ts_cid" && -n "$ts_csec" ]]; then
                        ts_token=$(curl -fsS -m 15 -u "$ts_cid:$ts_csec" -d "grant_type=client_credentials" https://api.tailscale.com/api/v2/oauth/token 2>/dev/null | jq -r '.access_token // empty') || true
                        [[ -n "$ts_token" ]] && ts_key=$(curl -fsS -m 15 -X POST -H "Authorization: Bearer $ts_token" -H "Content-Type: application/json" \
                            -d '{"capabilities":{"devices":{"create":{"reusable":false,"ephemeral":false,"preauthorized":true,"tags":["tag:dev"]}}},"expirySeconds":600,"description":"install.sh mini join"}' \
                            https://api.tailscale.com/api/v2/tailnet/-/keys 2>/dev/null | jq -r '.key // empty') || true
                    fi
                fi
                if [[ -n "$ts_key" ]]; then
                    sudo tailscale up --ssh --accept-dns --authkey="$ts_key" 2>/dev/null && echo "  [+] Tailscale up (SSH enabled)" || echo "  [!] tailscale up failed"
                elif tailscale status >/dev/null 2>&1; then
                    echo "  Already authenticated"
                    sudo tailscale set --ssh --accept-dns 2>/dev/null || true
                else
                    echo "  Not authenticated. Run: sudo tailscale up --ssh   (one-time browser login)"
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

        # Already joined? Reapply prefs and STOP — the mint path below also
        # deletes same-hostname tailnet nodes (ghost cleanup for fresh boots),
        # which on a re-run would delete this VM's own LIVE node mid-install
        # (dropping any tailnet SSH session driving the install) and rejoin
        # it as ephemeral. First boot was the only path this ever needed.
        if [[ "$(tailscale status --json 2>/dev/null | jq -r '.BackendState // empty')" == "Running" ]]; then
            echo "  Already authenticated (node untouched)"
            $SUDO tailscale set --ssh --accept-dns --accept-routes 2>/dev/null || true
            return 0
        fi

        # On exe.dev VMs, the tailscale-api integration proxy is reachable
        # and can generate auth keys without any secrets on disk. Use it
        # when TS_AUTHKEY wasn't provided explicitly.
        local ts_key="${TS_AUTHKEY:-}"
        if [[ -z "$ts_key" ]]; then
            local ts_proxy="https://tailscale-api.int.exe.xyz"
            # Two-step (U11, 2026-07): the proxy injects the Tailscale OAuth
            # client's Basic credentials on every request, so only the token
            # exchange goes through it; the 1h Bearer token then talks to the
            # public API directly. The exchange doubles as the reachability probe.
            local ts_token ts_api="https://api.tailscale.com"
            ts_token=$(curl -sL --connect-timeout 2 --max-time 15 -X POST -d "grant_type=client_credentials" \
                "$ts_proxy/api/v2/oauth/token" 2>/dev/null | jq -r '.access_token // empty') || true
            if [[ -n "$ts_token" ]]; then
                echo "  exe.dev proxy reachable — generating auth key (OAuth)"
                # Clean stale nodes with same hostname (prevents -2 suffix)
                local did
                for did in $(curl -sL -H "Authorization: Bearer $ts_token" "$ts_api/api/v2/tailnet/-/devices" \
                    | jq -r --arg h "$TS_HOSTNAME" '.devices[] | select(.hostname == $h) | .id'); do
                    curl -sL -X DELETE -H "Authorization: Bearer $ts_token" "$ts_api/api/v2/device/$did" >/dev/null
                done
                # Generate single-use ephemeral auth key
                ts_key=$(curl -sL -X POST -H "Authorization: Bearer $ts_token" "$ts_api/api/v2/tailnet/-/keys" \
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
            latest_version=$(echo "$release_json" | grep -oE '"tag_name": "[^"]+"' | head -1 | sed 's/"tag_name": "//;s/"//' || true)
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
            latest_version=$(echo "$release_json" | grep -oE '"tag_name": "[^"]+"' | head -1 | sed 's/"tag_name": "//;s/"//' || true)
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

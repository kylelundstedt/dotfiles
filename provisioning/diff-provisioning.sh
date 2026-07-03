#!/usr/bin/env bash
# Drift check: asserts the provisioning manifests and the two imperative
# installers (dotfiles install.sh, iv-image provision-iv.sh + vendor-skills.sh
# + agent/setup-mcp.sh) still agree. The manifests declare the "what"; each
# installer owns its "how" — this script only flags set divergence.
#
# Usage: diff-provisioning.sh [--manifest-dir DIR]
#   IV_IMAGE_DIR  iv-image clone (default ~/github/kylelundstedt/iv-image);
#                 iv-image-side checks are skipped with a warning if absent.
#
# Exit 0 = no drift; exit 1 = drift found. Run by test-install.sh (mode
# `provisioning`) and on demand after editing either installer or a manifest.
set -euo pipefail

MANIFEST_DIR="$(cd "$(dirname "$0")" && pwd)"
[[ "${1:-}" == "--manifest-dir" ]] && MANIFEST_DIR="$(cd "$2" && pwd)"
DOTFILES="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_SH="$DOTFILES/install.sh"
IV_IMAGE_DIR="${IV_IMAGE_DIR:-$HOME/github/kylelundstedt/iv-image}"

FAIL=0
ok()   { echo "  [ok]   $*"; }
drift() { echo "  [DRIFT] $*"; FAIL=1; }
skip() { echo "  [skip] $*"; }
info() { echo "  [info] $*"; }

have_iv=false
[[ -d "$IV_IMAGE_DIR" ]] && have_iv=true || skip "iv-image clone not found at $IV_IMAGE_DIR — skipping iv-image-side checks"

# Non-comment lines of a file (strips whole-line comments, keeps content)
code_lines() { grep -vE '^[[:space:]]*#' "$1"; }
# Manifest rows (comments + blanks stripped)
rows() { grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$MANIFEST_DIR/$1"; }

# --- skills ---------------------------------------------------------------
echo "=== skills.manifest ==="
# npx skill args as they appear in an installer, normalized to bare args
installer_skills() { # $1 = file
    code_lines "$1" | grep 'npx -y skills add -g -y' \
        | sed -E 's/.*npx -y skills add -g -y //; s/ *>\/dev\/null.*$//; s/ *\|\| true.*$//; s/[[:space:]]+$//'
}
install_sh_skills="$(installer_skills "$INSTALL_SH")"
vendor_skills=""; $have_iv && vendor_skills="$(installer_skills "$IV_IMAGE_DIR/vendor-skills.sh")"

while read -r layer method args; do
    if [[ "$method" == "curl" ]]; then
        # args = "<name> <url>" — presence checked by URL
        url="${args#* }"
        if grep -q "$url" "$INSTALL_SH"; then ok "skill (curl) $args in install.sh"; else drift "skill (curl) $args missing from install.sh"; fi
        if $have_iv; then
            if grep -q "$url" "$IV_IMAGE_DIR/vendor-skills.sh"; then ok "skill (curl) $args in vendor-skills.sh"; else drift "skill (curl) $args missing from vendor-skills.sh"; fi
        fi
        continue
    fi
    if grep -qxF "$args" <<<"$install_sh_skills"; then ok "skill $args in install.sh"; else drift "skill $args ($layer) missing from install.sh"; fi
    if $have_iv; then
        case "$layer" in
            team)     grep -qxF "$args" <<<"$vendor_skills" && ok "team skill $args vendored in iv-image" || drift "team skill $args missing from iv-image vendor-skills.sh" ;;
            personal) grep -qxF "$args" <<<"$vendor_skills" && drift "personal skill $args is ALSO vendored in iv-image (layer wrong?)" || ok "personal skill $args not in iv-image" ;;
        esac
    fi
done < <(rows skills.manifest)

# Reverse direction: every npx skill an installer adds must be in the manifest
manifest_skill_args="$(rows skills.manifest | awk '$2=="npx" {print substr($0, index($0,$3))}')"
while IFS= read -r args; do
    [[ -z "$args" ]] && continue
    grep -qxF "$args" <<<"$manifest_skill_args" || drift "install.sh installs unmanifested skill: $args"
done <<<"$install_sh_skills"
if $have_iv; then
    while IFS= read -r args; do
        [[ -z "$args" ]] && continue
        grep -qxF "$args" <<<"$manifest_skill_args" || drift "vendor-skills.sh vendors unmanifested skill: $args"
    done <<<"$vendor_skills"
fi

# --- mcp ------------------------------------------------------------------
echo "=== mcp.manifest ==="
setup_mcp="$IV_IMAGE_DIR/agent/setup-mcp.sh"
while IFS='|' read -r name layer vm mac; do
    name="$(echo "$name" | xargs)"; layer="$(echo "$layer" | xargs)"
    vm="$(echo "$vm" | xargs)"; mac="$(echo "$mac" | xargs)"
    # vm-url must appear in install.sh's Linux branch
    if [[ "$vm" != "-" ]]; then
        grep -qF "$vm" "$INSTALL_SH" && ok "mcp $name vm-url in install.sh" || drift "mcp $name vm-url $vm missing from install.sh"
    fi
    # mac column: direct URL, or pat:<account>:<op-ref> whose op-ref install.sh must read
    if [[ "$mac" == pat:* ]]; then
        opref="${mac#pat:*:}"
        grep -qF "$opref" "$INSTALL_SH" && ok "mcp $name PAT ref in install.sh" || drift "mcp $name PAT ref $opref missing from install.sh"
    else
        grep -qF "$mac" "$INSTALL_SH" && ok "mcp $name mac url in install.sh" || drift "mcp $name mac url $mac missing from install.sh"
    fi
    if $have_iv; then
        case "$layer" in
            team)     grep -qF "$vm" "$setup_mcp" && ok "team mcp $name seeded by iv-image" || drift "team mcp $name vm-url missing from iv-image setup-mcp.sh" ;;
            personal) grep -qF "\"$name\"" "$setup_mcp" && drift "personal mcp $name is ALSO seeded by iv-image (layer wrong?)" || ok "personal mcp $name not in iv-image" ;;
        esac
    fi
done < <(rows mcp.manifest)

# Reverse: every URL iv-image seeds must be a team row
if $have_iv; then
    while IFS= read -r url; do
        rows mcp.manifest | awk -F'|' '$2 ~ /team/ {gsub(/ /,"",$3); print $3}' | grep -qxF "$url" \
            || drift "iv-image setup-mcp.sh seeds unmanifested server url: $url"
    done < <(grep -oE 'https://[^"]+' "$setup_mcp")
fi
# Reverse: every `claude mcp add --transport http` URL in install.sh must be manifested (hub-mcp exempt: registered via $hub_url variable)
while IFS= read -r url; do
    rows mcp.manifest | awk -F'|' '{gsub(/ /,"",$3); gsub(/ /,"",$4); print $3; print $4}' | grep -qxF "$url" \
        || drift "install.sh registers unmanifested MCP url: $url"
done < <(code_lines "$INSTALL_SH" | grep 'claude mcp add --transport http' | grep -oE 'https://[^ ]+')

# --- tools ----------------------------------------------------------------
echo "=== tools.manifest ==="
prov="$IV_IMAGE_DIR/provision-iv.sh"
# Precompute code lines: grep -q at the end of a pipe trips pipefail (SIGPIPE
# on the producer when -q exits early), so match against variables instead.
install_code="$(code_lines "$INSTALL_SH")"
prov_code=""; $have_iv && prov_code="$(code_lines "$prov")"
while read -r layer tool; do
    case "$layer" in
        base) ok "base tool $tool (exeuntu-provided, informational)" ;;
        team)
            if $have_iv; then
                grep -qwF "$tool" <<<"$prov_code" && ok "team tool $tool in provision-iv.sh" || drift "team tool $tool missing from provision-iv.sh"
            fi
            grep -qwF "$tool" <<<"$install_code" && info "team tool $tool also installed by install.sh (macOS overlap — expected)" || true
            ;;
        personal)
            grep -qwF "$tool" <<<"$install_code" && ok "personal tool $tool in install.sh" || drift "personal tool $tool missing from install.sh"
            # provision-iv.sh guards every tool install with `command -v <tool>`,
            # so that's the precise signal (a bare word-grep false-positives on
            # e.g. .claude/ and codex-config.toml paths).
            if $have_iv; then
                grep -qE "command -v $tool\b" <<<"$prov_code" && drift "personal tool $tool is ALSO installed by provision-iv.sh (layer wrong?)" || true
            fi
            ;;
        *) drift "tools.manifest: unknown layer '$layer' for '$tool'" ;;
    esac
done < <(rows tools.manifest)

echo ""
if [[ $FAIL -eq 0 ]]; then echo "diff-provisioning: no drift"; else echo "diff-provisioning: DRIFT FOUND"; fi
exit $FAIL

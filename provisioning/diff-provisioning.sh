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

source "$DOTFILES/backup/_lib.sh"   # job_trim (canonical manifest-field trim)

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
# install.sh consumes the manifest directly (U3), so its check is "reads the
# manifest, hardcodes nothing". Per-row greps apply only to iv-image's
# vendor-skills.sh, which stays imperative until U5 pins the manifest.
if grep -q 'skills\.manifest' "$INSTALL_SH"; then ok "install.sh reads skills.manifest"; else drift "install.sh does not reference skills.manifest"; fi
hard_skills="$(code_lines "$INSTALL_SH" | grep 'npx -y skills add' | grep -v '\$s_args' || true)"
if [[ -n "$hard_skills" ]]; then drift "install.sh hardcodes skill installs (must come from skills.manifest):$hard_skills"; else ok "no hardcoded skill installs in install.sh"; fi

# iv-image side. Two states, auto-detected: after U5, vendor-skills.sh is a
# manifest consumer (pin + no hardcoded installs + pin-lag check); before it,
# legacy per-row literal checks apply.
if $have_iv; then
    if grep -q 'skills\.manifest' "$IV_IMAGE_DIR/vendor-skills.sh"; then
        ok "vendor-skills.sh reads skills.manifest (manifest consumer)"
        pin="$(tr -d '[:space:]' < "$IV_IMAGE_DIR/dotfiles-manifest.pin" 2>/dev/null || true)"
        if [[ "$pin" =~ ^[0-9a-f]{40}$ ]]; then
            ok "dotfiles-manifest.pin is a full SHA (${pin:0:12})"
            # Pin lag on the rows that matter: team rows at the pin vs local manifest
            if git -C "$DOTFILES" cat-file -e "$pin" 2>/dev/null; then
                pinned_team="$(git -C "$DOTFILES" show "$pin:provisioning/skills.manifest" 2>/dev/null | grep -vE '^[[:space:]]*#|^[[:space:]]*$' | awk '$1=="team"' || true)"
                current_team="$(rows skills.manifest | awk '$1=="team"')"
                if [[ "$pinned_team" == "$current_team" ]]; then
                    ok "team skill rows unchanged since iv-image pin"
                else
                    drift "team skill rows changed since iv-image's pin — rerun vendor-skills.sh (DOTFILES_SHA=<new sha>) in iv-image and commit"
                fi
            else
                skip "pin commit not in local dotfiles history — cannot check pin lag"
            fi
        else
            drift "iv-image dotfiles-manifest.pin missing or malformed"
        fi
        hard_vendor="$(code_lines "$IV_IMAGE_DIR/vendor-skills.sh" | grep 'npx -y skills add' | grep -v '\$args' || true)"
        if [[ -n "$hard_vendor" ]]; then drift "vendor-skills.sh hardcodes skill installs (must come from skills.manifest):$hard_vendor"; else ok "no hardcoded skill installs in vendor-skills.sh"; fi
    else
        # Legacy imperative vendor-skills.sh: per-row literal checks
        installer_skills() { # $1 = file
            code_lines "$1" | grep 'npx -y skills add -g -y' \
                | sed -E 's/.*npx -y skills add -g -y //; s/ *>\/dev\/null.*$//; s/ *\|\| true.*$//; s/[[:space:]]+$//'
        }
        vendor_skills="$(installer_skills "$IV_IMAGE_DIR/vendor-skills.sh")"
        while read -r layer method args; do
            if [[ "$method" == "curl" ]]; then
                url="${args#* }"
                if [[ "$layer" == "team" ]]; then
                    if grep -q "$url" "$IV_IMAGE_DIR/vendor-skills.sh"; then ok "team skill (curl) $args in vendor-skills.sh"; else drift "team skill (curl) $args missing from vendor-skills.sh"; fi
                fi
                continue
            fi
            case "$layer" in
                team)     grep -qxF "$args" <<<"$vendor_skills" && ok "team skill $args vendored in iv-image" || drift "team skill $args missing from iv-image vendor-skills.sh" ;;
                personal) grep -qxF "$args" <<<"$vendor_skills" && drift "personal skill $args is ALSO vendored in iv-image (layer wrong?)" || ok "personal skill $args not in iv-image" ;;
            esac
        done < <(rows skills.manifest)
        # Reverse direction: every npx skill iv-image vendors must be a team row
        manifest_skill_args="$(rows skills.manifest | awk '$2=="npx" {print substr($0, index($0,$3))}')"
        while IFS= read -r args; do
            [[ -z "$args" ]] && continue
            grep -qxF "$args" <<<"$manifest_skill_args" || drift "vendor-skills.sh vendors unmanifested skill: $args"
        done <<<"$vendor_skills"
    fi
fi

# --- agents-shared ----------------------------------------------------------
# provisioning/agents-shared.md is the canonical copy of the AGENTS.md
# sections shared between the personal file (embedded verbatim between
# shared markers) and the IV team file (vendored by iv-image at its pin).
echo "=== agents-shared.md ==="
shared_src="$MANIFEST_DIR/agents-shared.md"
extract_shared() { awk '/^<!-- >>> shared/{f=1;next} /^<!-- <<< shared/{f=0} f' "$1"; }
if [[ -f "$shared_src" ]]; then
    if diff -q <(extract_shared "$DOTFILES/agents/.agents/AGENTS.md") "$shared_src" >/dev/null 2>&1; then
        ok "personal AGENTS.md shared block matches agents-shared.md"
    else
        drift "personal AGENTS.md shared block differs from agents-shared.md — re-embed verbatim"
    fi
    if $have_iv && grep -q '>>> shared' "$IV_IMAGE_DIR/agent/AGENTS.md" 2>/dev/null; then
        iv_pin="$(tr -d '[:space:]' < "$IV_IMAGE_DIR/dotfiles-manifest.pin" 2>/dev/null || true)"
        if [[ "$iv_pin" =~ ^[0-9a-f]{40}$ ]] && git -C "$DOTFILES" cat-file -e "$iv_pin" 2>/dev/null; then
            if diff -q <(extract_shared "$IV_IMAGE_DIR/agent/AGENTS.md") \
                       <(git -C "$DOTFILES" show "$iv_pin:provisioning/agents-shared.md" 2>/dev/null) >/dev/null 2>&1; then
                ok "iv-image AGENTS.md shared block matches agents-shared.md at its pin"
            else
                drift "iv-image AGENTS.md shared block differs from agents-shared.md at pin ${iv_pin:0:12} — rerun vendor-skills.sh in iv-image"
            fi
            if diff -q <(git -C "$DOTFILES" show "$iv_pin:provisioning/agents-shared.md" 2>/dev/null) "$shared_src" >/dev/null 2>&1; then
                ok "agents-shared.md unchanged since iv-image pin"
            else
                drift "agents-shared.md changed since iv-image's pin — bump the pin (DOTFILES_SHA=<new> ./vendor-skills.sh) and commit in iv-image"
            fi
        else
            skip "iv-image pin unavailable — cannot check its shared AGENTS.md block"
        fi
    elif $have_iv; then
        skip "iv-image AGENTS.md has no shared markers yet (pre-U6 clone)"
    fi
else
    drift "provisioning/agents-shared.md missing"
fi

# --- mcp ------------------------------------------------------------------
echo "=== mcp.manifest ==="
setup_mcp="$IV_IMAGE_DIR/agent/setup-mcp.sh"
# install.sh consumes the manifest directly (U3): check "reads the manifest,
# hardcodes no URLs". Per-row greps apply only to iv-image's setup-mcp.sh.
if grep -q 'mcp\.manifest' "$INSTALL_SH"; then ok "install.sh reads mcp.manifest"; else drift "install.sh does not reference mcp.manifest"; fi
hard_mcp="$(code_lines "$INSTALL_SH" | grep 'claude mcp add --transport http' | grep -oE 'https://[^ "]+' || true)"
if [[ -n "$hard_mcp" ]]; then drift "install.sh hardcodes MCP urls (must come from mcp.manifest): $hard_mcp"; else ok "no hardcoded MCP urls in install.sh"; fi

# iv-image side, auto-detected like skills: after U5 the vendor step bakes
# agent/mcp-servers.json from the team rows and setup-mcp.sh just merges it;
# before U5, setup-mcp.sh carries the URLs inline.
if $have_iv; then
    servers_json="$IV_IMAGE_DIR/agent/mcp-servers.json"
    if [[ -f "$servers_json" ]] && command -v jq >/dev/null 2>&1; then
        # Exact-map compare: generated name->url must equal the team rows.
        # (Personal rows sneaking in would break equality too.)
        gen="$(jq -S 'with_entries(.value = .value.url)' "$servers_json")"
        want="$(rows mcp.manifest | awk -F'|' '$2 ~ /team/ {gsub(/^ +| +$/,"",$1); gsub(/^ +| +$/,"",$3); print $1"\t"$3}' \
            | jq -RnS 'reduce (inputs | split("\t")) as $r ({}; . + {($r[0]): $r[1]})')"
        if [[ "$gen" == "$want" ]]; then
            ok "iv-image mcp-servers.json matches mcp.manifest team rows"
        else
            drift "iv-image mcp-servers.json out of date vs mcp.manifest team rows — rerun vendor-skills.sh in iv-image and commit"
        fi
        grep -q 'mcp-servers\.json' "$setup_mcp" && ok "setup-mcp.sh merges mcp-servers.json" || drift "setup-mcp.sh does not use mcp-servers.json"
    else
        # Legacy inline setup-mcp.sh: per-row literal checks
        while IFS='|' read -r name layer vm mac; do
            name="$(job_trim "$name")"; layer="$(job_trim "$layer")"
            vm="$(job_trim "$vm")"
            case "$layer" in
                team)     grep -qF "$vm" "$setup_mcp" && ok "team mcp $name seeded by iv-image" || drift "team mcp $name vm-url missing from iv-image setup-mcp.sh" ;;
                personal) grep -qF "\"$name\"" "$setup_mcp" && drift "personal mcp $name is ALSO seeded by iv-image (layer wrong?)" || ok "personal mcp $name not in iv-image" ;;
            esac
        done < <(rows mcp.manifest)
        # Reverse: every URL iv-image seeds must be a team row
        while IFS= read -r url; do
            rows mcp.manifest | awk -F'|' '$2 ~ /team/ {gsub(/ /,"",$3); print $3}' | grep -qxF "$url" \
                || drift "iv-image setup-mcp.sh seeds unmanifested server url: $url"
        done < <(grep -oE 'https://[^"]+' "$setup_mcp")
    fi
fi

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

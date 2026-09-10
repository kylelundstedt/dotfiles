# Mac dotfiles-provisioning audit — klundstedt-mbp — 2026-09-10

Host: `klundstedt-mbp.localdomain` (arm64, Darwin 25.6.0).

Originally a read-only diagnosis per `provisioning/mac-audit.md`. **A remediation
pass was applied afterward at the user's request — see §2a. All four findings are
now resolved; the sections below preserve the original as-found state, annotated
with resolutions.**

## 1. Verdict

**As found:** This Mac is on the correct dotfiles-only (non-IV) provisioning
path, but it is not fully provisioned. Every structural assertion that proves the
full-install branch ran passes, there is no `iv-provision` coupling in
`install.sh`, and all three shared manifests are byte-identical across the two
repos. However **two real gaps exist that nothing currently guards**: the
`agentsview` team tool is missing, and the `github-home` MCP server is registered
but fails to connect. Three orphaned skills and four dangling skill symlinks are
also loading (or dangling) in agent sessions.

**After remediation (§2a):** correctly and fully provisioned by dotfiles alone.
All four findings fixed and verified; a presence guard was added to
`diff-provisioning.sh` (PR #38) so the silent-team-tool-drop class can't recur.

## 2. Failures

| #   | Finding                                                                                         | Class                                                        | Evidence                                                                                                                                                                                                                                                                                                                                                                                               |
| --- | ----------------------------------------------------------------------------------------------- | ------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 1   | `agentsview` (team tool) absent from this machine                                               | **drift** (machine ≠ manifest), unguarded                    | `command -v agentsview` → nothing; `brew list --cask agentsview` → no Caskroom dir; no `/Applications/AgentsView*`. `install.sh:603` runs `brew install --cask agentsview` but the failure is non-fatal (`…                                                                                                                                                                                            |     | echo "[!] agentsview brew install failed"`), so it stayed silently missing. `diff-provisioning.sh`only emits`[info] team tool agentsview also installed by install.sh` — a static reference check, exit 0. |
| 2   | `github-home` MCP **registered but fails to connect** in Claude Code                            | **failure / gap** (Part 4 mac column has no automated check) | `claude mcp list` → `github-home: https://api.githubcopilot.com/mcp/ (HTTP) - ✘ Failed to connect`. It _is_ registered (so 1Password was unlocked at last install — `github-work`, the other `pat:` row, is registered **and** `✔ Connected`), so this is the registered-but-rejected mode: the Home PAT (`op://Private/GitHub PAT Home/token`) is likely expired/invalid.                             |
| 3   | 3 orphaned skills loading into every agent session: `bootstrap-project`, `data-pipelines`, `zp` | **drift** (direction-2), caught                              | `./test-install.sh provisioning` → `FAIL: orphaned skills still loading into agent sessions: bootstrap-project data-pipelines zp`. Present in `~/.agents/skills/` and linked into `~/.claude/skills/`, not installed by `skills.manifest`. (`bootstrap-project`/`data-pipelines` were retired 2026-06-11.)                                                                                             |
| 4   | 4 dangling symlinks in `~/.claude/skills/`                                                      | **gap** (nothing checks this direction)                      | `installing-tigris-storage`, `tigris-bucket-management`, `tigris-object-operations`, `tigris-snapshots-forking` → targets missing in `~/.agents/skills/` (leftovers from the Tigris skill rename to `tigris-access-keys/authentication/buckets/iam/objects`). `test_skills_on_disk`'s "all 53 skills linked" only checks agents→claude (forward), so dangling claude→agents links are invisible to it. |

### Verdict/Failures printed to terminal

Findings 1 and 2 are the two that matter and that no automated check catches
(finding 3 is caught by `test-install.sh`; finding 4 is caught by nothing).

## 2a. Remediation (applied 2026-09-10, machine state + one repo change)

All four findings above are resolved. The table shows only machine-state
remediation; the repo-side guard is at the end.

| #   | Finding                                                         | Fix                                                                                                                                                    | Verification                                                                                                                                                                                                                                                                                |
| --- | --------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | `agentsview` absent                                             | `brew install --cask agentsview`                                                                                                                       | `agentsview v0.42.0` at `/opt/homebrew/bin/agentsview`; app at `/Applications/AgentsView.app`. **Root cause was the silent cask-install failure, not a dropped install.sh reference** — the reference was present.                                                                          |
| 2   | `github-home` MCP failed to connect                             | Re-read Home PAT from 1Password (interactive Touch ID approval), validated it, removed + re-added via `claude mcp add-json` matching `install.sh:1395` | Home PAT tested **HTTP 200** against `api.github.com/user` — **token was valid, not expired** (the §2 "likely expired" hypothesis was wrong); the registered entry had held a stale token from a prior install where 1Password was locked. `claude mcp list` → `github-home … ✔ Connected`. |
| 3   | 3 orphaned skills (`bootstrap-project`, `data-pipelines`, `zp`) | `rm -rf` from `~/.agents/skills/`, `~/.claude/skills/`, `~/.codex/skills/`                                                                             | `test-install.sh provisioning` → `PASS: no skills deleted from this repo are still installed`.                                                                                                                                                                                              |
| 4   | 4 dangling `~/.claude/skills/` symlinks                         | removed the dead links (`installing-tigris-storage`, `tigris-bucket-management`, `tigris-object-operations`, `tigris-snapshots-forking`)               | no dangling links remain (`for l in ~/.claude/skills/*; do [ -e "$l" ] …`).                                                                                                                                                                                                                 |

**Repo change — closes the finding-1 gap (PR #38).** Added a runtime presence
guard to `provisioning/diff-provisioning.sh`: on macOS (and not an IV VM), for
each team tool `install.sh` installs, it now asserts `command -v <tool>` instead
of only the static `[info] … also installed by install.sh`. VM-only team tools
(`shelley`, `render-site`, `provision-docsite`, `gen-llms-txt`,
`install-cloud-cli`) are excluded via the same install.sh-reference signal and
reported as expected-absent. No-op on Linux and IV VMs. Verified: negative test
emits `[DRIFT]` on an absent tool; full macOS run exits 0; `test-install.sh
provisioning` → 5/5. Committed on branch `drift-checker-team-tool-presence`,
pushed, PR opened — the `zsh/` working-tree edits were left untouched.

**Not fixed (unchanged from §3):** `motherduck`, `tigris`, `readwise` still show
`! Needs authentication` in Claude Code — OAuth session re-auth (interactive
browser dance), not provisioning drift.

## 3. Auth-state notes (not registration drift — reported per Part 4)

- Claude Code: `motherduck`, `tigris`, `readwise` all show `! Needs
authentication` — OAuth tokens expired/not completed. These are OAuth servers;
  re-auth is periodic, not a registration problem. All five manifest rows **are
  registered**.
- Codex: `motherduck`, `tigris`, `readwise` show `OAuth / enabled` in Codex's own
  token store (independent of Claude's) — no action implied by the above.

## 4. Expected absences (not failures)

- **VM-only team tools** (iv-provision installs on Linux): `shelley`,
  `render-site`, `provision-docsite`, `gen-llms-txt`, `install-cloud-cli` —
  absent = **expected** on a Mac.
- **`archil`** (`personal-linux`): install.sh installs it on Linux only; on a Mac
  it's the separate app or nothing — absent = **expected**.
- **`github-work` vm-url `-`**: by design (no VM carries a work-org repo
  integration; a work MCP on a VM 403s). Present + connected on this Mac.
- **Codex excludes `github-work`/`github-home`**: by design — Codex disallows
  inline bearer tokens, so the two `pat:` rows never register there.

## 5. Host-specific notes (mbp)

- **Tailscale = standard app.** `/usr/local/bin/tailscale` is the Tailscale.app
  CLI wrapper (73 bytes), installed via the `tailscale-app` **cask**. There is no
  `tailscale` brew **formula** and no `tailscaled` system daemon — that is the
  `--tailscale-ssh` path, which is `klundstedt-mini`-only. Correct for the mbp.
  Tailnet is up (mbp = `100.121.11.46`).
- **hub-mcp over tailnet.** Registered at
  `https://klundstedt-mini.dojo-sun.ts.net/mcp`; `✔ Connected` in Claude,
  `enabled` in Codex. Correct for a non-mini Mac (reaching the mini's server).
- **healthchecks.** `check-monitoring.sh` config-vs-manifest check passed
  (static). The live healthchecks.io ping (Keychain API key) is mini-only and
  self-skips here — **expected**.
- **launchd agents** (repo sync, Tigris backup, key-expiry) are mini-only; not
  applicable to the mbp.

## 6. Structural pass detail (Parts 1, 5, 6)

**Part 1 — non-IV path (all PASS):**

- `~/iv-provision.lock` absent ✓
- `~/.agents/AGENTS.md` is symlink → `../dotfiles/agents/.agents/AGENTS.md` ✓
- no `>>> personal overlay` splice in `~/.agents/AGENTS.md` ✓
- no `>>> iv-provision ssh` block in `~/.ssh/config` ✓
- `~/.claude/settings.json` is symlink → `../dotfiles/agents/.claude/settings.json` ✓
- shared block (`agents/.agents/AGENTS.md` lines 23–64) **byte-identical** to
  `provisioning/agents-shared.md` ✓

**Part 5 — cross-repo drift:** `skills.manifest`, `mcp.manifest`,
`agents-shared.md` all **byte-identical** between `~/dotfiles` and
`~/github/kylelundstedt/iv-provision` (fetched, `main` @ `19d8f4b`, clean).
`IV_PROVISION_DIR=… ./test-install.sh provisioning` ran the **iv-side checks**
(no `[skip] iv-image clone not found`; `[ok] iv-provision AGENTS.md shared
block…`, `[ok] iv-image mcp-servers.json…`, all team tools `[ok] in
provision-iv.sh`). Checker exit 0.

**Part 6 — dependency direction:** the only executable `install.sh` references
to iv-provision are the two harmless ones — the lock probe
(`install.sh:105  [[ -f "$HOME/iv-provision.lock" ]] && IS_IV_VM=true`) and the
ssh-marker parse (`install.sh:926  awk '/^# >>> iv-provision ssh >>>/…'`). Line
1376 is an `echo` string. **No executable line reads a path under an
iv-provision checkout.** No coupling.

**Setup note:** `~/dotfiles` is on `master`, up to date with `origin/master`, but
has two uncommitted working-tree changes (`zsh/.profile`, `zsh/.zshrc`). Neither
touches provisioning manifests, so findings above are not suspect — but the clone
is dirty.

## 7. Raw evidence

### 7a. tools.manifest vs PATH

| layer          | tool              | status                            | path                                          | version                         |
| -------------- | ----------------- | --------------------------------- | --------------------------------------------- | ------------------------------- |
| base           | git               | PRESENT                           | /opt/homebrew/bin/git                         | 2.53.0                          |
| base           | curl              | PRESENT                           | /usr/bin/curl                                 | 8.7.1                           |
| base           | jq                | PRESENT                           | /usr/bin/jq                                   | 1.7.1-apple                     |
| base           | tailscale         | PRESENT                           | /usr/local/bin/tailscale (Tailscale.app)      | 1.102.2                         |
| team           | duckdb            | PRESENT                           | ~/.local/bin/duckdb                           | v1.5.3                          |
| team           | quarto            | PRESENT                           | /usr/local/bin/quarto                         | 1.9.37                          |
| team           | aws               | PRESENT                           | /opt/homebrew/bin/aws                         | 2.33.25                         |
| team           | tigris            | PRESENT                           | ~/.local/bin/tigris                           | 3.0.0                           |
| team           | rclone            | PRESENT                           | /opt/homebrew/bin/rclone                      | v1.73.1                         |
| team           | herdr             | PRESENT                           | ~/.local/bin/herdr                            | 0.7.4                           |
| team           | **agentsview**    | ABSENT as-found → **now PRESENT** | /opt/homebrew/bin/agentsview                  | v0.42.0 (finding #1, fixed §2a) |
| team           | shelley           | ABSENT                            | —                                             | VM-only (expected)              |
| team           | render-site       | ABSENT                            | —                                             | VM-only (expected)              |
| team           | provision-docsite | ABSENT                            | —                                             | VM-only (expected)              |
| team           | gen-llms-txt      | ABSENT                            | —                                             | VM-only (expected)              |
| team           | install-cloud-cli | ABSENT                            | —                                             | VM-only (expected)              |
| team           | uv                | PRESENT                           | ~/.local/bin/uv                               | 0.11.15                         |
| team           | claude            | PRESENT                           | ~/.local/state/fnm_multishells/.../bin/claude | 2.1.175                         |
| team           | codex             | PRESENT                           | /opt/homebrew/bin/codex                       | 0.144.5                         |
| personal       | stow              | PRESENT                           | /opt/homebrew/bin/stow                        | 2.4.1                           |
| personal       | zsh               | PRESENT                           | /bin/zsh                                      | 5.9                             |
| personal       | starship          | PRESENT                           | ~/.local/bin/starship                         | 1.25.1                          |
| personal       | atuin             | PRESENT                           | ~/.atuin/bin/atuin                            | 18.16.1                         |
| personal       | direnv            | PRESENT                           | ~/.local/bin/direnv                           | 2.37.1                          |
| personal       | zoxide            | PRESENT                           | ~/.local/bin/zoxide                           | 0.9.9                           |
| personal-linux | archil            | ABSENT                            | —                                             | Linux-only (expected)           |
| personal       | fnm               | PRESENT                           | ~/.local/bin/fnm                              | 1.39.0                          |
| personal       | node              | PRESENT                           | ~/.local/state/fnm_multishells/.../bin/node   | v24.13.1                        |
| personal       | bat               | PRESENT                           | ~/.local/bin/bat                              | 0.26.1                          |
| personal       | fzf               | PRESENT                           | ~/.local/bin/fzf                              | 0.72.0                          |
| personal       | rg                | PRESENT                           | /opt/homebrew/bin/rg                          | 15.1.0                          |
| personal       | yq                | PRESENT                           | ~/.local/bin/yq                               | v4.53.2                         |
| personal-mac   | gh                | PRESENT                           | ~/.local/bin/gh                               | 2.92.0                          |
| personal       | carapace          | PRESENT                           | ~/.local/bin/carapace                         | 1.6.6                           |
| personal-mac   | croc              | PRESENT                           | ~/.local/bin/croc                             | v10.5.0                         |
| personal       | cship             | PRESENT                           | ~/.local/bin/cship                            | 1.7.1                           |
| personal       | snow              | PRESENT                           | ~/.local/bin/snow                             | 3.23.0                          |
| personal       | op                | PRESENT                           | /opt/homebrew/bin/op                          | 2.33.1                          |

(`claude`/`codex` resolve through shell aliases to the real binaries above; both
binaries present.)

### 7b. skills

`test-install.sh provisioning` → `PASS: every explicitly named manifest skill is
installed`; `PASS: all 53 skills linked into ~/.claude/skills`; **`FAIL:
orphaned skills … bootstrap-project data-pipelines zp`**.

Dangling `~/.claude/skills/` symlinks (targets missing in `~/.agents/skills/`):
`installing-tigris-storage`, `tigris-bucket-management`,
`tigris-object-operations`, `tigris-snapshots-forking`.

`~/.codex/skills/` (native reads `~/.agents/skills`, only a few linked here):
`archil-guide`, `bootstrap-project`, `data-pipelines`, `find-skills`,
`join-tailnet`, `mviz`, `upgrade-vm`, `zp` — all resolve.

### 7c. MCP servers

**Claude Code (`claude mcp list`) — manifest mac rows:**

| server          | url                                         | status                                                     |
| --------------- | ------------------------------------------- | ---------------------------------------------------------- |
| motherduck      | https://api.motherduck.com/mcp              | ! Needs authentication                                     |
| github-work     | https://api.githubcopilot.com/mcp/          | ✔ Connected                                                |
| github-home     | https://api.githubcopilot.com/mcp/          | ✘ Failed to connect as-found → **✔ Connected** (fixed §2a) |
| tigris          | https://mcp.storage.dev/mcp                 | ! Needs authentication                                     |
| readwise        | https://mcp2.readwise.io/mcp                | ! Needs authentication                                     |
| hub-mcp (probe) | https://klundstedt-mini.dojo-sun.ts.net/mcp | ✔ Connected                                                |

(Plus claude.ai-managed connectors: Mermaid, Gmail, Calendar, Notion, MotherDuck
connected; claude.ai Tigris needs auth — these are not from the manifest.)

**Codex (`codex mcp list`) — manifest non-`pat:` rows + hub-mcp:**

| server     | url                                         | status          |
| ---------- | ------------------------------------------- | --------------- |
| hub-mcp    | https://klundstedt-mini.dojo-sun.ts.net/mcp | enabled         |
| motherduck | https://api.motherduck.com/mcp              | enabled / OAuth |
| readwise   | https://mcp2.readwise.io/mcp                | enabled / OAuth |
| tigris     | https://mcp.storage.dev/mcp                 | enabled / OAuth |

(`cua_repl`/`node_repl` are the ChatGPT-app computer-use servers, not from the
manifest.)

## 8. Part 7 (fresh-install rehearsal) — NOT run

Requires creating a throwaway `dftest` user (~15 min) and was left for explicit
approval per the playbook. Not started.

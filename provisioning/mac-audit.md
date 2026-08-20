# Audit this Mac's dotfiles-only provisioning

## Context (read this first — it is the whole point of the task)

I maintain two provisioning layers that were recently **decoupled** so neither
depends on the other:

- `kylelundstedt/dotfiles` (`~/dotfiles`, `install.sh`) — the personal layer.
  On **Macs it is the ONLY provider**: shell, git, agents, every CLI tool.
- `kylelundstedt/iv-provision` (formerly `iv-image`) — the team baseline for
  exe.dev Linux VMs. It used to fetch its skill/MCP/tool manifests from the
  dotfiles repo at a pinned commit; as of 2026-08-18 it carries **its own copy**
  in `iv-provision/provisioning/` and the pin was retired.

`install.sh` branches on `IS_IV_VM`, set by the existence of
`~/iv-provision.lock`. On an IV VM it runs as a thin overlay: `want()` skips
every `team`-layer tool (iv-provision owns the pinned copy), team skills and
team MCP rows are skipped, and the personal `AGENTS.md` delta is spliced into
iv-provision's team file. **On a Mac none of that should happen** — the Mac must
take the full-install path.

The risk the decoupling created: there are now **two copies of the manifests**,
and the drift checker only content-compares one of the three files. So the Mac
can silently fall behind without anything going red.

**I want a diagnosis, not a repair.** Do not install, upgrade, or fix anything.
Do not run `install.sh`. Do not commit or push. Read state, compare it to what
the manifests declare, and report. If something is missing I want to know that
it was missing, not that you fixed it.

## Setup

```bash
cd ~/dotfiles
git fetch && git status -sb        # a stale/dirty clone makes every finding suspect — report it and continue
```

You also need an `iv-provision` clone to compare against. Check for one at
`~/iv-provision` or `~/github/kylelundstedt/iv-provision`; if neither exists,
clone it read-only (it is a public repo):

```bash
git clone https://github.com/kylelundstedt/iv-provision.git ~/github/kylelundstedt/iv-provision
```

This matters: `provisioning/diff-provisioning.sh` **skips all iv-side checks and
still exits 0** when it can't find that clone (line 43). A green run without the
clone is meaningless, and that is exactly the trap I want ruled out.

## Part 1 — the Mac must be on the non-IV path

These are the assertions that prove `install.sh` took the full-install branch.
Any failure means this Mac is being treated like a VM.

```bash
[ ! -f ~/iv-provision.lock ]                              # must NOT exist
[ -L ~/.agents/AGENTS.md ]                                # stow symlink into ~/dotfiles,
                                                          # not iv-provision's real file
readlink ~/.agents/AGENTS.md                              # should point inside ~/dotfiles
! grep -q '>>> personal overlay' ~/.agents/AGENTS.md      # overlay splice must NOT have run
! grep -q '>>> iv-provision ssh' ~/.ssh/config            # VM-only ssh block
[ -L ~/.claude/settings.json ]                            # stowed, not iv-provision-owned
```

Also confirm the shared-block contract holds locally: the block between the
`>>> shared` / `<<< shared` markers in `agents/.agents/AGENTS.md` must be
byte-identical to `provisioning/agents-shared.md`.

## Part 2 — tools.manifest vs what is actually on PATH

`provisioning/tools.manifest` has four layers. On macOS **all four should be
present** — `want()` only skips `team` on IV VMs, and `VM_SKIP_TOOLS` (gh, croc)
only applies on Linux. So every row is a claim about this machine.

For each row report: present/absent, `command -v` path, and version. Two things
I care about beyond presence:

- **`team` rows** (`duckdb quarto aws tigris rclone herdr agentsview uv claude
  codex` …) are the ones where the Mac's only provider is `install.sh`. The
  drift checker currently only asserts these against iv-provision's script, with
  a non-fatal `[info]` on the install.sh side — so a team tool could have been
  dropped from `install.sh` without anything going red. Verify each one exists.
- **`base` rows** (git curl jq tailscale) are informational on a VM but real on
  a Mac. Note that `tailscale` on macOS may come from the app bundle rather than
  `/opt/homebrew/bin` — record which, don't judge it.

The `shelley render-site provision-docsite gen-llms-txt install-cloud-cli` rows
are VM-only in practice (iv-provision installs them). Report their absence as
**expected**, not as a failure — but say so explicitly rather than skipping them.

## Part 3 — skills.manifest vs ~/.agents/skills

On macOS `install.sh` installs the `team`, `personal`, AND `mac` layers (Linux
VMs get team from iv-provision instead). Rows are `layer method args`; only
explicitly named skills are assertable — `npx <repo>` with no `-s` installs an
unknown set from upstream, `npx <repo> -s a b c` names them, and `curl <name>
<url>` names one.

Check both directions:
1. Every explicitly named skill in the manifest has `~/.agents/skills/<name>/SKILL.md`.
2. No skill that this repo once owned, has since deleted, and does not install
   via the manifest is still sitting on disk loading into every agent session.

`./test-install.sh provisioning` already implements both as `test_skills_on_disk`
— run it and read the output rather than reimplementing, but tell me which
direction any failure came from.

Also verify the `~/.claude/skills/` and `~/.codex/skills/` symlinks resolve —
a skill can be on disk in `~/.agents/skills` and invisible to both agents.

## Part 4 — mcp.manifest vs registered MCP servers

`provisioning/mcp.manifest` is `name | layer | vm-url | mac`. On macOS the
**mac column** is what applies, and it is the column that **no automated check
covers at all** — `diff-provisioning.sh` only validates the vm-url side against
iv-provision's generated `agent/mcp-servers.json`. So this part is genuinely
unguarded and is the most likely place to find real drift.

```bash
claude mcp list
codex mcp list
```

Expected on a Mac: all five rows registered in Claude Code
(`motherduck github-work github-home tigris readwise`) — the two `pat:` rows
(`github-work`, `github-home`) read a token from 1Password at install time, so
if 1Password was locked during the last `install.sh` they will be **absent**,
which is a real finding worth reporting. Codex gets only the non-`pat:` rows
(`motherduck tigris readwise`) plus `hub-mcp`, because Codex disallows inline
bearer tokens.

Report **connection status**, not just presence — `claude mcp list` shows
connected/failed, and a registered-but-403 server is the failure mode I have hit
before (that is why `github-work`'s vm-url is `-`).

`hub-mcp` is deliberately not in the manifest: `install.sh` probes for it
dynamically — `localhost` on `klundstedt-mini`, the tailnet URL on other Macs,
absent if unreachable. Report what you find without treating absence as failure
unless this is the mini.

## Part 5 — the cross-repo drift the checker does not catch

Three files exist in **both** repos under `provisioning/`. Diff each pair:

```bash
for f in skills.manifest mcp.manifest agents-shared.md; do
  diff ~/dotfiles/provisioning/$f <IV_PROVISION_CLONE>/provisioning/$f
done
```

Only `agents-shared.md` is content-compared by `diff-provisioning.sh`. The
skills check on the iv side degraded to `grep -q 'skills\.manifest'
vendor-skills.sh` — it asserts the script *reads a manifest*, not that the
manifests *agree*. `mcp.manifest`'s mac column is compared to nothing.

As of 2026-08-20 all three were byte-identical when checked from the
`iv-provision` VM. If they differ on this Mac, either the Mac's dotfiles clone
is stale or someone edited one copy — distinguish those two by checking whether
`origin/master` is ahead.

Then run the checker properly:

```bash
cd ~/dotfiles
IV_PROVISION_DIR=<IV_PROVISION_CLONE> ./test-install.sh provisioning
```

Confirm from the output that iv-side checks actually **ran** (no
`[skip] iv-image clone not found`). On `klundstedt-mini` this also runs
`check-monitoring.sh` against healthchecks.io using the Keychain API key; on the
mbp that self-skips, which is expected.

## Part 6 — the dependency direction, mechanically

The claim "Macs are provisioned by dotfiles only" should be checkable, not
believed. `install.sh` may reference iv-provision in exactly two harmless ways:
the `~/iv-provision.lock` existence probe, and the `>>> iv-provision ssh >>>`
markers it parses in `~/.ssh/config` to avoid clobbering that block.

```bash
grep -n 'iv-image\|iv-provision\|IV_IMAGE\|IV_PROVISION' ~/dotfiles/install.sh
```

Every other hit should be a comment. Report any line that is executable code
reading a path under an iv-provision checkout — that would be a real coupling
and the single most important thing you could find.

## Part 7 (OPTIONAL — ask me before doing this)

Everything above audits a machine that is already installed. It cannot tell me
whether a **fresh** Mac would come up correctly, because `install.sh` is
idempotent: `need()` short-circuits every tool already on PATH, so a re-run
proves nothing.

The cheap rehearsal is a throwaway local user:

```bash
sudo sysadminctl -addUser dftest -fullName "dotfiles test" -password -
sudo -u dftest -i bash -lc 'curl -fsSL https://raw.githubusercontent.com/kylelundstedt/dotfiles/master/install.sh | bash'
# re-run Parts 1-4 as dftest
sudo sysadminctl -deleteUser dftest
```

This exercises self-bootstrap, stow into a virgin HOME, and agent config from
scratch. **Its known limitation is `/opt/homebrew`, which is shared** — brew
formulae will read as already-installed, so the brew path is not really tested.
If you run it, make that visible: log which tools were installed versus skipped
as already present, rather than reporting a clean pass that overstates coverage.

Do not start this without asking me. It creates a user account and takes ~15
minutes.

## Output

Write `~/mac-audit-<hostname>-<date>.md` containing:

1. **Verdict** — one line: is this Mac correctly provisioned by dotfiles alone?
2. **Failures** — each with the file/line or command that produced it, and
   whether it is a *drift* (machine ≠ manifest), a *gap* (nothing checks this),
   or *expected* (VM-only tool, locked 1Password, etc.). Do not pad the list
   with expected absences; put those in a separate short section.
3. **Host-specific notes** — mini: launchd agents loaded, healthchecks drift,
   tailscale brew formula + `tailscaled` daemon state, hub-mcp on localhost.
   mbp: standard Tailscale app, hub-mcp over tailnet.
4. **Raw evidence** — the tool/skill/MCP tables, so I can diff the two Macs
   against each other.

Print the verdict and the failures section to the terminal too. Be concrete:
"claude mcp list shows github-home absent" beats "some MCP servers may not be
configured".

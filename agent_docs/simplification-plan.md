# Dotfiles Simplification Plan

Comprehensive review of the dotfiles repo (2026-07-03), driven by three changes:
the `kylelundstedt/iv-image` derivative image for exe.dev VMs, the new
`personal-mcp/` server, and the cross-harness-memory convention. Goals:
**simplify, remove redundancy with iv-image, improve performance** across
Ubuntu VMs and the two macOS machines (`klundstedt-mini`, `klundstedt-mbp`).

## Status (2026-07-05, supervised resume in progress)

Branch `plan/low-risk-subset` reviewed + merged (`a17bb60`). **U3 done** on
master: `install.sh` skills/MCP sections now read the provisioning manifests
(stub-harness verified: planned command set identical to the old hardcoded
set for Linux + macOS claude, codex, and both skills paths);
`diff-provisioning.sh` install.sh-side checks flipped to "reads the manifest,
hardcodes nothing". **Caveat:** the plan's real-run verify on klundstedt-mbp
is still pending — do a `./install.sh` there before trusting a fresh-machine
path.

**U5 done — iv-image#1 merged 2026-07-10** after the throwaway-VM check
passed (stock exeuntu, `tag:iv`: 35 skills vendored + symlinked for both
harnesses, MCP == exactly the team rows via proxy URLs, lockfile records the
pin, tools present; VM deleted). Note: per-repo integrations attached at
`new --integration=…` take ~1 min to propagate — retry the first clone.
Design decision at
execution: MCP servers are baked at _vendor_ time into a generated
`agent/mcp-servers.json`, like skills — provisioning stays no-network;
`dotfiles-manifest.pin` = `d8e3c4d`). Re-vendored: identical 35-skill set +
2 MCP servers. `diff-provisioning.sh` is dual-mode (auto-detects pre/post-U5
iv-image clones, including a pin-lag check on team rows). **Gotcha fixed
en route (`3d4cebb`):** manifest read-loops must feed on fd 9 — npx eats
stdin and silently dropped 34 of 35 rows; install.sh had the same bug in all
four U3 loops. **U8 done (2026-07-10, `4b8c092`):** personal-mcp split to the private
`kylelundstedt/personal-mcp` repo (filter-repo, 16 commits preserved;
self-locating scripts; plists at the `~/github` clone path; `bootstrap.sh`).
Deployed on the mini and verified before removal from dotfiles: all 4 jobs
loaded from the new location, server live from the new clone, healthcheck
job kickstarted under launchd (exit 0). check-key-expiry LaunchAgent also
now stowed + loaded (closes U12's deploy). **U9 done (2026-07-10):** python/CLI half delegated to a Sonnet subagent
per the plan's tiering (lib/embed.py + 3 consumers rewired, 15/15 tests;
web search wrappers folded into hub/search.sh --semantic with byte-identical
output; _DEDUP_KEY_SQL hoisted — which surfaced that _semantic_messages had
been using a tuple _approximation_ of the key that could over-collapse
SMS/iMessage; now canonical). Launchd half here: hub/rebuild-hub.sh
(failure-isolated, ATTACH guard verified), inline hub block removed from
web-archive-refresh.sh, cascade rescheduled (03:00 / 03:30 / 04:00 /
backup 04:30 — collision gone). All deployed + kickstart-verified under
launchd on the mini. Open: create the healthchecks.io check for
personal-mcp:hub-healthcheck-url. **Next:** U10 → U6 → U7 → U11.

Unplanned fix (2026-07-05): multi-day healthcheck flapping on sync-repos +
tigris-backup diagnosed and fixed (`ab1d21e`) — gitconfig_macos SSH rewrite
beating the job's HTTPS rewrite, lastrun written on failed runs (skip pinged
success over red), and iCloud-Drive .Trash breaking the home backup. The
shared-helper consolidation of these scripts remains U10.

## Status (2026-07-03, unattended first pass — done)

**U1, U2, U4, U12 complete** on branch `plan/low-risk-subset` (one commit per
unit, not pushed; working checkout returned to master so launchd runs only
merged code). All self-checks passed. Executed on the mini by Fable 5 —
**inline, not delegated to the H/S tiers the table assigns** (deviation
acknowledged; delegate cheap tiers at the resume).

Needs eyes at the supervised resume:

- **U1 / SSH-guard hook:** not present in the mini's live (gitignored)
  `settings.json` — presumably on the mbp. Example synced with what was
  verifiable here (model pin, `tui`); add the hook from the mbp's copy.
- **U12 / expiry dates:** Tailscale auth keys + 3 GitHub PATs are
  `expires: unknown` in `keys.manifest` (not recorded anywhere in-repo; `op`
  off-limits unattended). Fill from GitHub settings / Tailscale console.
- **U12 / warn window:** set to **35d, not the ~14d below** — a monthly check
  with a 14d window would have missed the Aug 21 Tailscale deadline (Aug 1 run
  → 20d left → silent). Deliberate deviation.
- **U12 / rotation runbook:** exact `ssh exe.dev integrations add` flags for
  the http-proxy re-add aren't documented locally — verify via
  `ssh exe.dev help` and backfill `secrets.md`.
- **U4 / scope addition:** `test-install.sh`'s hard TS_AUTHKEY/1Password
  requirement is now gated to VM-creating modes so the local `provisioning`
  and `hook` modes run without `op`.
- The `com.kylelundstedt.check-key-expiry.plist` is created but **not loaded**;
  it deploys via the normal stow + login path. Its Keychain healthcheck item
  (`key-expiry:healthcheck-url`) is not provisioned yet (needs `op`).

Next: review + merge the branch, then the supervised-resume sequence below
(U3 → U5 → U8 → U9 → U10 → U6 → U7 → U11).

## Core decision

**On exe.dev VMs, personal dotfiles are a _thin personal overlay_ on top of
`iv-image`'s `provision-iv.sh` — not a second full provisioner.** `iv-image`
owns the VM baseline (tools, team `AGENTS.md`, MCP proxies, skills, VM-to-VM SSH
stanza). `install.sh` on a VM should add only the personal delta and skip
anything iv-image already lays down.

This makes "performance on VMs" mostly a byproduct of not redoing iv-image's
work, rather than a separate optimization track.

### What iv-image already provisions (verified from `provision-iv.sh`, main)

- Tools (pinned, `/usr/local/bin`): `duckdb`, `quarto`, `aws`, `tigris`, `rclone`; `install-cloud-cli` helper for azure/gcloud on demand.
- Agent config: IV team `~/.agents/AGENTS.md`, `~/.claude/settings.json`, `~/.codex/config.toml`, `CLAUDE.md`/`AGENTS.md` symlinks.
- MCP: `motherduck`, `github-work` seeded into `~/.claude.json` (`agent/setup-mcp.sh`).
- Skills: fully vendored, copied to `~/.agents/skills` + symlinked into `.claude`/`.codex`.
- SSH: appends an `iv-provision` block to `~/.ssh/config` (`Host iv-* *.ts.net` → `accept-new`, `User exedev`).

## Core decision 2 — `personal-mcp` moves to its own private repo

`personal-mcp` is an application (own `pyproject.toml`/`uv.lock`/tests), runs on
**one host** (mini-only, capability-guarded), and iterates on its own cadence —
yet dotfiles is **public** and `curl|bash`-cloned onto every VM, so today it (a)
leaks PII into a public repo (personal + work email in `msgvault-sync.sh:20`, the
`dojo-sun.ts.net` tailnet, the mini hostname, backup-bucket architecture in the
README) and (b) ships the whole Python app onto VMs that never run it.

**Decision: extract to a private repo `kylelundstedt/personal-mcp`, cloned to
`~/github/kylelundstedt/personal-mcp`** (the personal-repo convention; sync-repos
already mirrors the `kylelundstedt` org incl. private, so the mini gets it
automatically, and the gitconfig `includeIf` gives it the personal identity).

Clean responsibility line — **serving vs consuming the hub:**

- New repo owns (serving, mini-only): `mcp/`, ingest scripts, build SQL,
  `_common.sh`, build/refresh LaunchAgents, its READMEs, and a `bootstrap.sh`
  that symlinks its plists into `~/Library/LaunchAgents` + loads them and seeds
  its own Keychain items (`personal-mcp:*-healthcheck-url`).
- **dotfiles keeps (consuming, all machines):** the `hub-mcp` MCP _client_
  registration in `install.sh:867-908,1003-1007` (an env-config concern) and
  `tigris-backup.sh` (backup is a dotfiles concern; `~/archives` is the contract
  between the two repos, not the repo boundary).

What leaves dotfiles: the `personal-mcp/` tree; the 4 plists
(`personal-mcp`, `personal-mcp-healthcheck`, `msgvault-sync`,
`web-archive-refresh`, plus the new `rebuild-hub`); the `personal-mcp/` rows in
`TODO.md`, `agent_docs/README.md`, `agent_docs/personal-mcp.md`.

Mechanics: preserve history with `git filter-repo --path personal-mcp/`; rewrite
the `$HOME/dotfiles/personal-mcp` path strings (`web-archive-refresh.sh:17`,
`calendar-refresh.sh:14`, plists, README) to `$HOME/github/kylelundstedt/personal-mcp`
— or better, make the scripts self-locate via `$(dirname "${BASH_SOURCE[0]}")` so
only the plists carry the absolute path.

Caveats (honest): mini setup becomes two commands (`dotfiles/install.sh` +
`personal-mcp/bootstrap.sh`); the split fixes only _go-forward_ exposure — the
public dotfiles history still contains the leaked emails/tailnet (already public;
rewriting it is a separate, low-value call).

## Core decision 3 — one declarative source for "what gets provisioned"

Both provisioners today declare the _same_ things imperatively, so they drift.
Concrete proof: `install.sh:1049-1057` and iv-image `vendor-skills.sh:18-26`
share a **byte-identical 6-line skill block** — edit one, forget the other, and
they silently diverge.

Principle (same as decisions 1 & 2): **separate the "what" (a declarative list)
from the "how" (per-platform apply), layered `team baseline` + `personal delta`.**
Don't unify the _installers_ — the tool-install recipe (arch/asset patterns, brew
vs apt vs release-binary, `~/.local/bin` vs `/usr/local/bin`) is legitimately
mechanism-specific, and versions stay divergent on purpose (iv-image pins for team
reproducibility; dotfiles floats). Unify only the _lists_.

**Decision: manifests for skills + MCP, plus a tool drift-check; manifests live in
dotfiles (public — content is non-secret).** New `provisioning/` dir (not stowed):

- `provisioning/skills.manifest` — columns `layer method args`
  (`team|personal`, `npx|curl`). `install.sh` reads it locally: macOS installs
  `team`+`personal`, Linux installs `personal` only (team comes vendored in the
  image). Kills the duplicated block.
- `provisioning/mcp.manifest` — columns `name layer vm-url mac`
  (the VM proxy-URL vs Mac direct-URL/`pat:op://…` difference becomes _data_).
  `install.sh` applies the `mac` column; iv-image `setup-mcp.sh` applies the
  `vm-url` for `team` rows. (`hub-mcp` stays special — dynamic reachability probe.)
- `provisioning/tools.manifest` + `provisioning/diff-provisioning.sh` — declares
  the intended per-layer tool _set_ (`base` = exeuntu-provided, `team` = iv-image,
  `personal` = dotfiles-only); the check asserts each installer covers its layer
  and flags divergence. Run in `test-install.sh` / on demand.

**Cross-repo mechanics:** iv-image's `vendor-skills.sh` + `setup-mcp.sh` `curl`
the raw manifests from the public dotfiles repo **at a pinned commit** (not
`master`) — so the team image stays reproducible even though dotfiles owns the
source of truth. This resolves the pin-vs-float tension: dotfiles is the list;
iv-image pins _which revision_ of the list it baked.

This makes the overlay model uniform across every category: **iv-image = team
baseline; dotfiles = personal delta + (on macOS) applies both.** AGENTS.md
(decision 1) is the one category where the content itself — not just the list —
is shared; the same `provisioning/`-owned, iv-image-pins-the-ref pattern applies.

## Core decision 4 — API key management

Problems: credential expiry is tracked only by a `TODO.md` checkbox (miss it and
`join-tailnet` / MCP / sync-repos break); rotation fans out from 1Password to the
login Keychain + the exe.dev integration + the MCP configs; the multi-step ritual
is what makes rotation get deferred.

Decisions:

- **Tailscale: migrate the API key → an OAuth client** — non-expiring, `tag:dev`-scoped,
  mints auth keys on demand. Eliminates the **2026-08-21** deadline _and_ all future
  Tailscale rotations, and can replace the static `iv-internal-dev`/`iv-internal-test`
  auth keys (mint on demand). **Verify at execution** that the exe.dev `tailscale-api`
  integration accepts an OAuth client (not just an API-key bearer); fall back to
  rotate-in-place if not. Touches: the integration, `install.sh:1140` (macOS `tailscale up`),
  `test-install.sh`, and the join-tailnet skill's proxy.
- **Runbook:** extend `agent_docs/secrets.md` with a credential inventory — per key:
  1P vault/item, type, expiry, fan-out targets, exact rotation command.
- **Expiry alarm:** record expiry dates machine-readably (a `provisioning/keys.manifest`
  or a table `secrets.md` parses) + a monthly launchd check on the healthchecks.io
  pattern already in use, warning when any key is within ~14 days.
- **Not now (defer, ties to #8 on-hold):** GitHub App installation tokens (auto-refresh,
  no PAT rotation — heavier); sync-repos reading PATs via an `op` service account at
  runtime to drop the Keychain copies.

## Findings

### 1. dotfiles ↔ iv-image overlap (the main lever)

Running the full `install.sh` Linux path over `provision-iv.sh` duplicates or
collides on:

- **Tools** — `duckdb`/`quarto`/`tigris` installed by both (dotfiles `need`-guards mostly no-op these once iv-image's copies are on PATH; the genuine personal delta is `starship, uv, atuin, zoxide, direnv, fnm, bat, fzf, rg, gh, carapace, cship`).
- **Agent instructions** — `install.sh` stows the **personal** `~/.agents/AGENTS.md` over iv-image's **team** one. The two share ~5 near-identical sections (Code, Data Work, TODO, Skills, exe.dev SSH) maintained in two repos → drift risk. Last writer wins.
- **MCP** — `install.sh` re-adds `motherduck`/`github-work` that iv-image already seeded, plus personal-only `github-home`/`tigris`/`readwise`.
- **SSH config** — `install.sh:565` _overwrites the whole `~/.ssh/config`_, wiping iv-image's appended block. Benign today (install.sh's own `Match host *.ts.net … tag:dev` covers VM-to-VM; VMs verified to carry `tag:dev`), but it's two mechanisms for one job.
- **Skills** — already gated macOS-only (`install.sh:1047-1061`). This is the clean model to extend to the rest of the VM path.

### 2. personal-mcp internal duplication

- Embedding endpoint/model/dim (`localhost:1234`, `nomic-embed-text`, `768`) copy-pasted across ≥5 files (`mcp/server.py`, `web/embed_reader.py`, `web/semantic.sh`, `calendar-archive/embed_calendar.py`, health probes). No shared config.
- `web/embed_reader.py` ≈ `calendar-archive/embed_calendar.py` (~90% identical).
- Shell search wrappers (`hub/search.sh`, `web/search.sh`, `web/semantic.sh`) duplicate the MCP `search`/`semantic_search` tools — pre-MCP tooling, now superseded.
- Email dedup key implemented 3× (`hub/build_hub.sql:42`, twice in `server.py`).
- **Latent bug:** hub rebuild is buried in `web-archive-refresh.sh:61`; a Readwise pull failure `exit 1`s at `:36` _before_ the rebuild, so a Reader outage silently staleness-blocks email + calendar hub updates. Hub rebuild should be its own failure-isolated step.

### 3. Automation boilerplate

- 20h-staleness + `/tmp/*.lastrun` + `mkdir`-lock reimplemented in `sync-repos.sh` and `backup/tigris-backup.sh`.
- `hc()` (healthcheck) + Keychain-read helpers copy-pasted across `sync-repos.sh:33`, `tigris-backup.sh:51`, `restore-drill.sh` → extract a shared `backup/_lib.sh` (mirrors `personal-mcp/_common.sh`).
- `sync-repos.plist` + `sync-repos-wakeup.plist` differ only by trigger — could be one plist with both keys.
- **Scheduling collision:** `tigris-backup` and `web-archive-refresh` both fire at **04:00** and both touch `~/archives/*.duckdb` (backup copies `web-archive.duckdb` while refresh rewrites it). Stagger refresh to 04:30.

### 4. Docs / config hygiene (dispositions decided)

- **Delete** `agent_docs/snowflake-auth-policy.md` (16 KB, dated) and
  `agent-shell-eval.md` — point-in-time artifacts, and drop their `agent_docs/README.md`
  rows + the `TODO.md` agent-shell section.
- **Add** the Memory-convention restatement to the dotfiles root `AGENTS.md`
  (global `AGENTS.md:41` asks for it and this repo is where the convention is defined).
- **Sync** `agents/.claude/settings.json.example` to the live gitignored file
  (add the SSH-guard hook + model pin) so the example isn't stale.
- `agent_docs/README.md` index missing rows already fixed alongside this doc.

## Plan (priority order)

1. **Slim `install.sh`'s VM path to a personal overlay.** Gate the Linux/exe.dev
   path on `[ -d /exe.dev ]` and skip what iv-image owns: don't stow the personal
   `AGENTS.md` over the team one (or reconcile them — see below), don't re-add
   iv-image's MCP servers, don't overwrite `~/.ssh/config`. Install only the
   personal tool delta and personal-only MCP servers (`github-home`, `tigris`,
   `readwise`). Extend the skills-gating pattern already at `install.sh:1047`.
   - Pairs with **Core decision 3**: build `provisioning/{skills,mcp,tools}.manifest`
     - `diff-provisioning.sh` first, then have both `install.sh` and iv-image
       (`vendor-skills.sh`, `setup-mcp.sh`) consume them. The overlay's skill/MCP
       gating _is_ the manifest `layer` column, so the manifests underpin item 1.
       Cross-repo: an iv-image change (curl the pinned manifest) ships alongside.
   - **AGENTS.md reconciliation — decided: (c).** De-dup the shared ~5 sections
     into the iv-image team `AGENTS.md` (the baseline); the personal dotfiles
     `AGENTS.md` keeps only its true deltas (personal tone/prefs, personal skills,
     memory convention) and no longer restates what the team file already says.
     On a VM the overlay leaves the team file in place and layers the personal
     delta; on macOS dotfiles supplies both. Same `provisioning/`-owned,
     iv-image-pins-the-ref pattern as decision 3.
2. **Split `personal-mcp` to its own private repo** (Core decision 2) — do this
   _before_ its de-dup so the file moves are a clean `git mv`, not a rebase over
   refactors.
3. **De-dup `personal-mcp` (in the new repo):** `lib/embed.py`; hub CLI
   consolidation; hub-rebuild as its own failure-isolated job; reschedule cascade.
4. **Extract `backup/_lib.sh`** (staleness/lock/healthcheck/Keychain) shared by
   `tigris-backup.sh` + `sync-repos.sh` + `restore-drill.sh`; stagger to 04:30.
   Stays in dotfiles; independent of the split.
5. **Docs/config cleanup — ✅ done (U1):** delete `snowflake-auth-policy.md` +
   `agent-shell-eval.md` (and their index/TODO rows); add the Memory restatement
   to root `AGENTS.md`; sync `settings.json.example` (SSH-guard hook still
   pending — see Status).
6. **API key management** (Core decision 4): runbook + expiry alarm **✅ done
   (U12)**; Tailscale API-key → OAuth client (U11) still open and retires the
   time-sensitive 2026-08-21 rotation. Largely independent of the
   boundary/split work.

### Sequencing

`split → personal-mcp de-dup (new repo) → backup/_lib.sh (dotfiles)`. The
reschedule cascade spans both repos but is only plist times. The VM personal
overlay (item 1) + `provisioning/` manifests (decision 3) come after — largest,
and a coordinated dotfiles-PR + iv-image-PR pair. API-key work (item 6) can slot
anywhere; do the Tailscale OAuth migration before 2026-08-21 regardless.

## Execution units (dispatchable task graph)

Tiered **by risk** (per decision): `H`=Haiku, `S`=Sonnet (cheap, delegatable),
`★`=strong orchestrator model (Fable 5 / Opus), `★+H`=strong + human-in-loop.
Cheap units are delegatable only because each has a self-checkable acceptance
test; without that, a strong-model review erases the savings. Mechanism (Fable-5
manual subagents vs the Workflow tool) decided at execution time.

| ID     | Unit                               | Key files                                                                                                                       | Tier                         | Deps                             | Verify (done-when)                                                                      | Risk   |
| ------ | ---------------------------------- | ------------------------------------------------------------------------------------------------------------------------------- | ---------------------------- | -------------------------------- | --------------------------------------------------------------------------------------- | ------ |
| U1 ✅  | Docs cleanup                       | `agent_docs/{snowflake-auth-policy,agent-shell-eval}.md` (del), README, `TODO.md`, root `AGENTS.md`, `settings.json.example`    | H                            | —                                | `prettier --check`; no dangling links; example matches live keys                        | low    |
| U2 ✅  | Manifest data files                | `provisioning/{skills,mcp,tools}.manifest` (new)                                                                                | S                            | —                                | awk parse smoke-test; row counts == current install set                                 | low    |
| U4 ✅  | Drift-check                        | `provisioning/diff-provisioning.sh`; hook into `test-install.sh`                                                                | S                            | U2                               | flags a deliberately-injected drift                                                     | low    |
| U12 ✅ | API-key runbook + alarm            | `agent_docs/secrets.md`, `provisioning/keys.manifest`, `check-key-expiry.sh` + plist                                            | S                            | —                                | `check-key-expiry.sh` dry-run warns <14d                                                | low    |
| U10    | `backup/_lib.sh`                   | `backup/_lib.sh` (new), `tigris-backup.sh`, `sync-repos.sh`, `restore-drill.sh`, merge 2 sync plists                            | ★                            | —                                | `restore-drill.sh` + one manual `tigris-backup` run **(mini)**; behavior byte-identical | high   |
| U3     | Manifest consumers (dotfiles)      | `install.sh` skills+MCP sections                                                                                                | ★                            | U2                               | `--dry-run` + real run on mbp: skills/MCP set unchanged; `test-install.sh`              | med    |
| U5     | Manifest consumers (iv-image) + PR | iv-image `vendor-skills.sh`, `agent/setup-mcp.sh`                                                                               | ★                            | U2 pushed (pinned SHA)           | throwaway VM: team skills/MCP present                                                   | med    |
| U8     | personal-mcp split                 | `git filter-repo` → private `kylelundstedt/personal-mcp`; path fixups; `bootstrap.sh`; move 4 plists (+ rebuild-hub)            | ★+H                          | —                                | fresh clone + bootstrap **(mini)**; plists load; server reachable                       | high   |
| U9     | personal-mcp de-dup (new repo)     | `lib/embed.py` + 4 consumers, one hub `search.sh --semantic`, `hub/rebuild-hub.sh` + ATTACH guard, `_DEDUP_KEY_SQL`, reschedule | S (python/CLI) / ★ (launchd) | U8                               | `test_server.py` + manual cascade **(mini)**                                            | med    |
| U6     | AGENTS.md reconciliation (c)       | iv-image `agent/AGENTS.md` (absorb shared), dotfiles `agents/.agents/AGENTS.md` (trim to deltas)                                | ★                            | coordinate both repos            | read-through: no rule lost                                                              | med    |
| U7     | VM overlay                         | `install.sh` (gate `/exe.dev`; skip iv-owned agent/MCP/SSH; personal delta only)                                                | ★                            | U3, U6                           | `test-install.sh` exe path on a VM; team baseline intact                                | med-hi |
| U11    | Tailscale → OAuth client           | OAuth client (tag:dev); `install.sh:1140`, `test-install.sh`, join-tailnet proxy; retire API key + static auth keys             | ★                            | verify integration accepts OAuth | `join-tailnet` on a fresh VM                                                            | med    |

**Done (branch `plan/low-risk-subset`):** U1, U2, U4, U12 — see Status at top.
**Next:** U10; U3 (U2 is in); U5 after the branch merges + pushes (pinned SHA).
**Serialize:** U8 → U9. **Later phase:** U6 → U7. **Anytime:** U11.

**Delegatable to cheap models:** U1, U2, U4, U12, and U9's python/CLI half.
Everything else is destructive, subtle bash, outward-facing, DR-critical, or
cross-repo — kept on the orchestrator.

**Mini-gated verification:** U8 (deploy), U9 + U10 (verify) require klundstedt-mini.
An orchestrator must batch these behind an SSH-to-mini step, not hand them to a
worker that can't reach the archives/LM Studio.

## Execution on klundstedt-mini

The mini is the execution host — it alone has the live `~/archives` + LM Studio
needed for U8/U9/U10. Pull `~/dotfiles` manually first (`refresh-env.sh` auto-pulls
only on exe.dev VMs, not Macs). Run Fable 5 as a **supervised** orchestrator, not
fire-and-forget: the plan has human-in-loop (U8), outward-facing (U5/U6/U11), and
VM-gated (U3/U5/U7/U11) units, and `op`/1Password is not unlocked in a headless SSH
session.

### Unattended first pass (operator away — low-risk subset only) — ✅ done

Completed 2026-07-03; results and follow-ups in **Status** at the top. Protocol
was, for the record — scope **U1, U2, U4, U12 only**:

- Work on a branch `plan/low-risk-subset` off master — do **not** commit to master or push.
- Per unit: make the edits, run its self-check, commit to the branch with a clear message:
  - U1 → `npx prettier --check` on touched Markdown + no dangling links; example matches live settings keys.
  - U2 → awk column parse of each manifest; row counts equal the current install set (`install.sh` skills/MCP + iv-image `vendor-skills.sh`).
  - U4 → run `diff-provisioning.sh` against a deliberately-injected drift and confirm it flags it.
  - U12 → `check-key-expiry.sh` dry-run warns within ~14 days; runbook table complete (no `op` needed to author it).
- Do **not**: load/reload any LaunchAgent; change any deployed script's behavior on the live host; run `op`/1Password; SSH to exe.dev or any VM; start U3/U5/U6/U7/U8/U9/U10/U11.
- If a self-check fails or a unit needs a decision, **stop and leave a note** — do not guess.
- End state: a reviewable branch + a short summary (what passed, what needs eyes) for the resume.

### Supervised resume (operator back)

Review + merge the branch, then proceed in sequence: U3 (wire in U4) → U5 (after
the manifests are pushed, at a pinned SHA) → U8 → U9 (on the mini, verified vs
`~/archives`) → U10 (cautious; `restore-drill.sh`) → boundary U6 → U7 → U11. Keep
the branch/worktree isolation so launchd never runs half-finished code — deploy
(checkout swap + plist reload) only after each unit's verify passes.

## De-dup implementation detail (plan items 3 + 4, planned 2026-07-03)

Decisions locked: **keep one hub CLI** (not all three wrappers, not zero);
**`backup/_lib.sh` only** (leave `personal-mcp/_common.sh` as-is). The 2a–2e work
below lands in the **new `personal-mcp` repo** (post-split); the `backup/_lib.sh`
work stays in dotfiles. Paths shown relative to each repo root.

### 2a. `personal-mcp/lib/embed.py` — shared embedding primitives

Stdlib-only (json + urllib) so every consumer imports it regardless of venv —
no dependency change to any path.

```python
ENDPOINT, MODEL, DIM = "http://localhost:1234/v1/embeddings", "text-embedding-nomic-embed-text-v1.5@q8_0", 768
BATCH, MAXCHARS = 64, 6000
def embed(inputs): ...        # batch list->list
def embed_query(text): ...    # "search_query: " + single
def doc_input(parts): ...     # "search_document: " + " ".join(parts)[:MAXCHARS]
```

Consumers to rewire (drop their local copies):

- `mcp/server.py:48-49,110-124` → import for `ENDPOINT`/`MODEL`/`embed_query`; `DIM` replaces the four hardcoded `768` (incl. `::FLOAT[768]` in `_semantic_web`/`_semantic_calendar`). `sys.path` insert to the sibling `lib/`.
- `web/embed_reader.py:24-41` and `calendar-archive/embed_calendar.py:33-50` → import for `ENDPOINT`/`MODEL`/`BATCH`/`MAXCHARS`/`embed`/`doc_input`. **Keep the two drivers separate** (their load/write halves differ: jsonl vs DuckDB); only the config/`embed()` dup is removed, so the web path stays stdlib `python3` (no new uv dep).
- `web/semantic.sh` → folded into the hub CLI below (deleted).

### 2b. Hub CLI consolidation

- Delete `web/search.sh` + `web/semantic.sh` (web-only, subsumed by the hub + MCP tools).
- Keep **one** `hub/search.sh` (or promote to `personal-mcp/search.sh`) over `hub.duckdb` — spans all sources. Add a `--semantic` mode that shells `python3 lib/embed.py --query "$Q"` to get the vector literal, replacing the deleted `web/semantic.sh`.

### 2c. Extract hub rebuild + fix ordering bug

- New `personal-mcp/hub/rebuild-hub.sh`: own lock + `pm_hc hub`, the existing atomic temp-swap. Guard `build_hub.sql`'s `ATTACH` of `messages.duckdb` so a missing one-time-backfill file doesn't fail the whole build.
- Delete the inline hub block from `web-archive-refresh.sh:57-66` — removes the bug where a Reader-pull `exit 1` (`:36`) skips the rebuild, staleness-blocking email+calendar hub freshness.
- New LaunchAgent `com.kylelundstedt.rebuild-hub.plist`.

### 2d. Reschedule cascade (also fixes the 04:00 backup/refresh collision)

| Job                 | Now   | New   |
| ------------------- | ----- | ----- |
| msgvault-sync       | 03:00 | 03:00 |
| web-archive-refresh | 04:00 | 03:30 |
| rebuild-hub (new)   | —     | 04:00 |
| tigris-backup       | 04:00 | 04:30 |

### 2e. Dedup key (minor, low priority)

Centralize the two SQL copies in `server.py:218,306` into one `_DEDUP_KEY_SQL`
constant; leave `build_hub.sql:42` with a cross-reference comment (don't force it
across the .sql/.py boundary).

### 3. `backup/_lib.sh` (backup + sync only)

Functions: `job_kc <svc> <key>`, `job_hc <url> [path] [curl-args]`,
`job_lock <name>`, `job_stale_skip <name> <interval>`, `job_mark_done <name>`,
`job_log <name> <logdir>`, plus `tigris_rclone_env` (the crypt-remote export block
duplicated between `tigris-backup.sh:68-78` and `restore-drill.sh`).

Sourced by `tigris-backup.sh`, `sync-repos.sh`, `restore-drill.sh`. Behavior kept
byte-identical (these are unattended DR jobs) — verify via `restore-drill.sh` + a
manual run. Also merge `sync-repos.plist` + `sync-repos-wakeup.plist` into one
plist carrying both `StartCalendarInterval` and `StartInterval`.

### Verification constraint

Archives live on **klundstedt-mini**; dev happens on **klundstedt-mbp**.
personal-mcp ingest/hub changes can only be end-to-end verified on the mini over
the tailnet (`test_server.py` skips off-host). Stage as commits, verify on the
mini before trusting the schedule.

## Open questions

All planning decisions are settled (decisions 1–4; AGENTS.md → (c); docs
dispositions; Tailscale → OAuth; runbook + expiry alarm). Remaining are
execution-time items, not blockers:

- **Public-history rewrite** — decided: **leave as-is** (the split stops
  go-forward leakage; scrubbing past commits is disruptive and mostly futile
  since it's already public).
- **Verify at execution:** exe.dev `tailscale-api` integration accepts an OAuth
  client (else rotate-in-place); `build_hub.sql` ATTACH guard on `messages.duckdb`.
- **Cross-repo:** decisions 1 & 3 ship as a coordinated dotfiles-PR + iv-image-PR
  pair (iv-image edits made from here via branch + PR).
- **Verification host:** personal-mcp de-dup + launchd deploy happen on
  klundstedt-mini; dotfiles-side edits from anywhere.

Out of scope (held per user): other `TODO.md` items — per-project 1P service
account, `install.sh` swallowed-error hygiene, agent-shell / Basic Memory evals.

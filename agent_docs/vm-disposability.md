# VM disposability — is "git and Tigris hold all permanent state" true?

> Audited 2026-07-28, prompted by the dev-lane question in
> [vm-disk-weight.md](vm-disk-weight.md). If VMs are genuinely disposable, then
> rebuilding one on a new base image is free and no migration plan is needed —
> the image question dissolves. So the invariant was tested rather than assumed.
>
> **Verdict: true, once 10 commits were pushed.** The entire gap across six dev
> VMs was **10 unpushed commits on two hosts**, cleared 2026-07-28. Everything else is pushed, regenerable, or
> already centralised. The systemic weakness is not on the VMs at all — it is
> that the mini's Tigris backup is currently failing.

## Method

A read-only audit on each tailnet-joined dev VM classified everything under
`~` into: reproducible by provisioning, tracked in git with a clean and fully
pushed remote, or neither. Repos were checked for a remote, dirty worktree,
untracked files, commits absent from all remotes, and local branches with no
upstream. Shelley/Claude/Codex state and gitignored payloads were sized
separately.

## What is actually at risk

| Host                  | At risk                                                                      |
| --------------------- | ---------------------------------------------------------------------------- |
| `iv-gitlake-examples` | **7 unpushed commits** on `main` (`ahead 7`) — real feat/fix work            |
| `iv-docs`             | **3 unpushed commits**, plus branch `entire/checkpoints/v1` with no upstream |
| `iv-home`             | nothing                                                                      |
| `iv-gitlake`          | nothing                                                                      |
| `kgl-thoughts`        | nothing                                                                      |
| `iv-ave-adapters`     | nothing                                                                      |

That is the whole gap. Destroying the other four VMs right now would lose
nothing.

### The 1.1G that looked alarming and isn't

`iv-gitlake-examples` carries 1.1G of gitignored payload, which at first reads
like unbacked-up data. It is `tpch-mortgage/out/`, `out-dev-a/`, `out-dev-b/`
(336M each) plus two `.venv` directories — generated benchmark output and
virtualenvs, all reproducible from the committed pipeline. Correctly ignored,
correctly absent from git, and not a gap.

## Shelley state — covered, with one real caveat

> **Which database to query.** `~/.agentsview/sessions.db` is the collector's
> **live** database; `~/archives/agentsview/sessions.db` is a periodic
> **snapshot** staged for backup. Querying the archive to check whether a newly
> enrolled source is collecting returns nothing and looks like a failure — the
> data is in the live DB and only reaches the archive at snapshot time. The
> table below is snapshot-derived, so treat its counts as as-of-last-snapshot,
> not live.

The reasonable worry is that Shelley sessions live only on the VM. The archive
says otherwise: AgentsView is collecting Shelley history from every dev VM, and
for the active ones it is current to today.

| Machine               | shelley sessions | newest           |
| --------------------- | ---------------: | ---------------- |
| `iv-docs`             |               91 | 2026-07-28 05:47 |
| `kgl-thoughts`        |               49 | 2026-07-23 14:45 |
| `iv-gitlake-examples` |               28 | 2026-07-25 18:12 |
| `iv-home`             |               17 | 2026-07-28 02:22 |
| `iv-gitlake`          |                5 | 2026-07-22 14:20 |

Claude and Codex history is collected alongside it (`kgl-thoughts` 110 claude +
7 codex, `iv-docs` 31 claude). So **completed Shelley history is not in the
gap** — this is exactly the job AgentsView was built for, and it is doing it.

Three caveats worth holding:

1. **In-flight sessions are not covered.** The archive holds session records;
   a Shelley session running mid-task when the VM dies is not a completed
   session, and its working context goes with the box. Disposability means
   "destroy when idle", not "destroy at any instant".
2. **AgentsView is still a pilot**, adoption due ~2026-08-04, with retention
   and token fan-out unresolved ([agentsview-pilot.md](agentsview-pilot.md)).
   The invariant currently rests on an unadopted mechanism.
3. **Collection recency varies.** `iv-docs` and `iv-home` are current to today;
   `kgl-thoughts` newest is 2026-07-23 and its claude history 2026-07-17. The
   healthcheck reports no failed syncs, so this is most likely just inactivity
   — but it is inferred, not verified, and worth confirming before relying on
   it for a destroy.

## The real weakness is offsite, not on the VMs

VM state funnels to the mini (AgentsView) and to GitHub (git). The mini is then
backed up to Tigris — and **that backup is currently failing**: the 2026-07-28
04:30 run ended `DONE WITH FAILURES: home(rc=1) photos(rc=1)` with 4,835 copy
errors in the home phase. So the last hop of the chain is broken, which matters
far more than any VM's local disk. Triage is open; see
[tigris-backup-runbook.md](tigris-backup-runbook.md) and
[monitoring.md](monitoring.md).

## Consequence for the dev lane

The earlier recommendation — "adopt a slim base for new VMs only, never
migrate" — was premised on dev VMs holding state too valuable to recreate. The
audit does not support that premise. With 10 commits pushed, four of the six
VMs are disposable today and the other two become so immediately after.

So the sequencing is:

1. ~~Push the 10 commits~~ — **done 2026-07-28**. All six dev VMs now report
   zero unpushed commits. `entire/checkpoints/v1` was already on the remote;
   Entire's hook pushes it alongside `main`, so it needed no separate action.
2. Fix the Tigris backup — the invariant's last hop.
3. Decide AgentsView adoption (~2026-08-04); until then the Shelley half of
   the invariant rests on a pilot.
4. Then rebuild dev VMs on the slim base **when convenient, idle, and one at a
   time** — no migration project, no state rescue. And every future base bump
   is equally cheap, which is the durable win.

Retiring `kgl-dotfiles` (2026-07-22) required manually archiving its Shelley
database and repo bundles to `~/archives/vm-retirements/`. That was the
evidence suggesting the invariant did not hold. It is largely obsolete now:
AgentsView post-dates it and covers what had to be rescued by hand.

## Two records, two durability models — AgentsView vs Entire

Both capture agent activity, so the instinct is to ask whether both are needed
on every VM. That framing hides the real difference: **AgentsView is
host-scoped infrastructure; Entire is repo-scoped configuration.** The useful
question is "AgentsView on which hosts, Entire on which repos".

|                           | AgentsView                                          | Entire CLI                                                 |
| ------------------------- | --------------------------------------------------- | ---------------------------------------------------------- |
| Where the record lives    | external copy on the mini                           | inside the repo, ref `entire/checkpoints/v1`               |
| How it gets there         | collector **pulls** from a live host on an interval | **pushed** with the code — a hook fires on `git push`      |
| Survives instant VM death | only what was already synced                        | yes, once pushed — it is just git                          |
| Scope                     | every agent, every host, including work in no repo  | one repo, only checkpointed work                           |
| Answers                   | "what did agents do across the fleet"               | "why is this code the way it is"                           |
| Retention                 | unbounded local growth, **policy but no mechanism** | **permanent** in git history, unprunable without a rewrite |

Verified 2026-07-28: pushing `main` on `iv-docs` emitted
`[entire] Pushing entire/checkpoints/v1 to origin.... done`. Entire's record
inherits the code's durability automatically — no daemon, no interval, no
coverage check. **For the disposability invariant, Entire is strictly stronger
where it applies.** But it only applies to repo-scoped checkpointed work, which
is the minority of what happens on these VMs.

Current footprint: Entire is installed on **one** VM (`iv-docs`, CLI 0.8.42),
with 13 commits / 6 checkpoints / 51 files / 2.9 MB in a 10M `.git` — roughly
0.5 MB per checkpoint, growing monotonically and permanently.

### Recommendation

- **AgentsView — every host where an agent runs.** It is the catch-all and the
  safety net: ops work in no repo, exploration, debugging, and above all
  Shelley, which is the dominant agent here (`iv-docs`: 91 Shelley sessions vs
  13 Entire checkpoints). Already true today; keep it.
- **Entire — per repo, not per VM.** Enable it on repos whose "why" is worth
  keeping for years; skip scratch and canary repos. It follows the repository
  to whatever machine works on it, which is the point.
- **Neither on deployment-lane VMs.** `rss-feed` has neither, correctly — no
  agent work happens there.

They are not redundant. Entire gives provenance a reviewer can read in a PR
without tailnet access; AgentsView gives fleet-wide recall across everything,
including work that never became a commit. Dropping either loses something the
other cannot supply.

### Two sequencing points before any broad Entire rollout

1. **Shelley coverage is still being built.** `kylelundstedt/entire-agent-shelley`
   is active and unfinished (commits 2026-07-26: "expose plugin to Entire hook
   subprocess", "resolve Entire outside Shelley PATH"), with `iv-entire-agent-shelley`
   created the same day for clean-install qualification. Until it lands, Entire
   covers Claude/Codex but not the bulk of VM agent activity. Rolling it out
   fleet-wide first would instrument the minority.
2. **Decide Entire's retention policy before enabling it widely, not after.**
   AgentsView's retention gap is fixable whenever — it is local files. Entire's
   record is permanent git history; the decision is effectively irreversible
   per repo. The two systems need opposite policies, and only one of them
   forgives a late decision.

## Audit v2 — what v1 missed (2026-07-28)

v1's repo discovery was `find -maxdepth 3 -type d -name .git`. Three structural
blind spots, and two of them hid real work:

1. **Linked worktrees are invisible to `-type d`** — a worktree's `.git` is a
   **file**. `iv-docs` has 9 (`~/worktrees/ave-*`), `iv-home` 1,
   `iv-foundry-stage2` several. v1 saw none of them.
2. **`maxdepth 3` was too shallow** — it missed
   `~/github/kylelundstedt/ave-adapters`, which is where those 9 worktrees are
   anchored.
3. **Un-joined VMs were never audited at all.** `iv-foundry-stage2` and
   `iv-entire-agent-shelley` are not on the tailnet, so they were unreachable
   by name and silently omitted.

v2 also checks stashes, detached-HEAD commits, local-only tags, and notes refs.
All came back zero fleet-wide — but v1 could not have seen them either.

### What v2 surfaced

- `iv-docs` — **1** genuinely unpushed commit, `e94c04e docs: freeze M1 package
runtime boundary` on `p1-s1-m1-package-runtime`. **Pushed.** Note the 9
  worktrees share one object store, so each reported the same count: it was one
  commit seen ten times, not ten commits.
- `iv-foundry-stage2` — **8 unpushed commits**: 5 Entire checkpoint transcripts
  in `worktrees/fannie-sflpd`, and 3 in
  `worktrees/fannie-sflpd-preauth-20260727` whose `main` is an **unrelated
  history** (`Initial commit`, `Initialize metadata ref`). Not pushed —
  pushing that second one at `origin/main` would be wrong, not merely noisy.
- `iv-entire-agent-shelley` — clean.
- `.codex/.tmp/plugins` on two VMs — a vendored upstream clone with its remote
  stripped, not our work. Disposable.

### The structural finding: installed is not the same as working

`iv-foundry-stage2` runs **both** safety nets and gets **neither**:

- **AgentsView** — binary present (v0.38.1 from iv-image), but
  `~/.config/agentsview/source.env` is absent, so the fail-closed daemon never
  starts. The VM is also not on the tailnet, so nothing could reach it anyway.
- **Entire** — installed (`~/.local/bin/entire`, 50M) with its hooks in place
  (`pre-push`, `post-commit`, …). But Entire ships its record **on push**, and
  nothing has been pushed since 2026-07-27. Five checkpoints sat local.

And the check that exists to catch exactly this could not see it:
**`agentsview-coverage` enumerates online Linux _tailnet peers_.** A VM that
never joined the tailnet is not a peer, so it is not flagged. The fail-closed
guarantee is closed against joined hosts and **open against un-joined ones** —
which is precisely where the 8 commits were. The authoritative VM inventory is
`ssh exe.dev ls --json` ([exe-dev-web.md](exe-dev-web.md)); coverage should be
driven from that, not from the tailnet.

Both assertions were implemented on 2026-07-28 and are described below.

### Resolution — all VMs enrolled, 2026-07-28

The coverage change flagged three uncovered VMs on its first run, one of which
(`telnyx-vm`) had been created that same day. All three are now enrolled:

| VM                        | What it is                                                                                              |
| ------------------------- | ------------------------------------------------------------------------------------------------------- |
| `iv-entire-agent-shelley` | where the private Shelley adapter for the Entire CLI was built                                          |
| `iv-foundry-stage2`       | dogfooding the IV CLI against fannie-sflpd; M1–M2 done, M3 halted awaiting Fannie support on API access |
| `telnyx-vm`               | voicemail/SMS forwarding to email, and the Zoom→Telnyx number port                                      |

Enrollment notes worth keeping:

- `telnyx-vm` was untagged, so it had no `tailscale-api` integration. That
  integration was attached **on its own** rather than adding the `iv` tag,
  which would have pulled in every IV-scoped integration onto a telephony box.
- It was joined with **`--accept-dns=false`**. It runs live voicemail
  forwarding and an in-flight number port; rewriting `/etc/resolv.conf` on a
  box that must reach the Telnyx API is a risk with no upside, since the
  collector resolves _it_, not the reverse. Verified afterwards: resolv.conf
  still `1.1.1.1`, `telnyx-webhook.service` still active.
- `telnyx-vm` and `iv-entire-agent-shelley` had no AgentsView binary at all.
  Only the AgentsView pieces were installed — pinned to 0.38.1 and
  checksum-verified exactly as `provision-iv.sh` does — rather than running the
  full IV layer, which would have put DuckDB, Quarto, the AWS CLI and the rest
  onto a service VM.

Verified collecting, not merely reachable: `iv-foundry-stage2` 20 Shelley
sessions (newest 2026-07-28 22:40 — the fannie-sflpd milestone work),
`telnyx-vm` 4, `iv-entire-agent-shelley` 3. Note that "N source(s) reachable"
from the healthcheck probes each configured host directly; it does **not**
prove the collector has pulled anything. The three new hosts were reachable
for ~15 minutes before their first fan-out, so reachability and collection
must be checked separately.

Result: 9 configured sources, 1 excused (`rss-feed`), 0 uncovered. Coverage
reports `rss-feed` as "a running exe.dev VM but not an online tailnet peer",
which is the correct shape for a deployment-lane VM and is precisely the case
the old tailnet-only pass could not see.

## telnyx-vm — the one VM that is genuinely not disposable

Audited 2026-07-28 only after it joined the tailnet, and it changes the fleet
picture. Its code **is** in a private repo (`kylelundstedt/telnyx-vm`) and was
6 commits behind — those commits _were_ the porting record (LOA revisions,
Zoom account details captured, port submission with SIP/SMS routing). Pushed.

But it runs an **irreversible business process** — an in-flight Zoom→Telnyx
number port — and three categories of material sat only on that host:

| Item                                                                                                    | Disposition (2026-07-28)                                                                                                                                              |
| ------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `porting-private/` (716K, gitignored): signed LOA, two unsigned revisions, Zoom invoice/number evidence | Copied to `~/Documents/IndustryVault/Telnyx/`, checksums verified. `~/Documents` is not excluded from the Tigris backup, so it goes offsite once that job is healthy. |
| `/etc/telnyx-webhook.env` — `SMS_WEBHOOK_TOKEN`, mode 0600                                              | Stored in 1Password (`Employee` vault, "Telnyx webhook (telnyx-vm)").                                                                                                 |
| `provision-state.json`, `logs/*.jsonl` — provisioning state + live delivery logs                        | Still host-only. Operational rather than irreplaceable; left in place.                                                                                                |

**Why the documents do not belong in the repo.** The split the repo already
uses is the right one and should be kept: `porting-state.json` is committed and
records _flags_ (`zoom_port_out_pin_saved: true`), never the PIN itself — which
is exactly why those 6 commits were safe to push. The PDFs are a different
class: they are PII-bearing legal documents (service address, account holder,
signature), they are binary, and git is append-only — committing them is a
one-way door that would require a history rewrite to undo, and the repo is
cloned onto the VM itself. Keep the record in git, keep the documents out.

**Third audit blind spot, recorded with the other two:** the audit only ever
scanned `$HOME`. `/etc/telnyx-webhook.env` was invisible to it. Service
credentials commonly live outside `$HOME`, so a disposability audit that stops
at the home directory will miss exactly the files that make a service VM
unrebuildable.

## Audit v3 — re-run after adoption, 2026-07-28

Re-run across all nine tailnet hosts once the last three VMs were enrolled, and
extended to close the third blind spot: **state outside `$HOME`**. v1 and v2
only ever walked the home directory, which is how `/etc/telnyx-webhook.env`
stayed invisible on the one VM running an irreversible process. v3 enumerates
running system and user units and reports any `EnvironmentFile`/`ExecStart`
path outside `$HOME` that actually exists.

Result — the fleet is clean:

- **Zero unpushed work.** The only two hits are `.codex/.tmp/plugins` on
  `iv-gitlake-examples` and `kgl-thoughts`: vendored upstream clones with their
  remote stripped, sitting in a `.tmp` directory. Regenerable, not our work.
- **One out-of-`$HOME` secret of ours, already handled:**
  `/etc/telnyx-webhook.env` (mode 0600), now mirrored in 1Password.
- **`/exe.dev/shelley.json` (mode 0644) on every VM** is platform-injected by
  exe.dev, not ours. Keys are `default_model`, `key_generator`, `links`,
  `llm_gateway`, `terminal_url` — no credential material, and it is recreated
  when a VM is created. Not a gap, but worth knowing it is world-readable.

The disposability invariant now holds fleet-wide, tested rather than assumed,
with the audit covering main repos, linked worktrees, stashes, detached HEAD,
local-only tags, notes refs, un-joined VMs, and service state outside `$HOME`.

## Audit gotcha

The first pass reported `AGENTSVIEW_UNIT=inactive` on all six VMs, which
contradicted the collector's own "6 source(s) reachable". The probe was wrong:
`agentsview-source.service` is a **user** unit, so a system-scope
`systemctl is-active` misses it. Any fleet probe for it must use
`systemctl --user`, or check the listener on `:8080` instead.

Second instance, same class: `command -v entire` reported absent on
`iv-foundry-stage2`, but the binary is there (`~/.local/bin/entire`, 50M).
Non-interactive SSH gets `PATH=/bin:/usr/bin:/sbin:/usr/sbin:/exe.dev/bin:/usr/local/bin`
— no `~/.local/bin`. **Any fleet probe over `ssh <host> '<cmd>'` must test
absolute paths, not `command -v`**, or it will report every user-installed tool
missing. Both false negatives were caught only because they contradicted
something already known.

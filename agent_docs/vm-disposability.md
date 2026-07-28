# VM disposability — is "git and Tigris hold all permanent state" true?

> Audited 2026-07-28, prompted by the dev-lane question in
> [vm-disk-weight.md](vm-disk-weight.md). If VMs are genuinely disposable, then
> rebuilding one on a new base image is free and no migration plan is needed —
> the image question dissolves. So the invariant was tested rather than assumed.
>
> **Verdict: very nearly true.** The entire gap across six dev VMs is **10
> unpushed commits on two hosts**. Everything else is pushed, regenerable, or
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

1. Push the 10 commits (`iv-gitlake-examples` ×7, `iv-docs` ×3) and give
   `entire/checkpoints/v1` an upstream or delete it.
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

## Audit gotcha

The first pass reported `AGENTSVIEW_UNIT=inactive` on all six VMs, which
contradicted the collector's own "6 source(s) reachable". The probe was wrong:
`agentsview-source.service` is a **user** unit, so a system-scope
`systemctl is-active` misses it. Any fleet probe for it must use
`systemctl --user`, or check the listener on `:8080` instead.

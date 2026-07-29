# exe.dev remediation — capability exposure + disk weight

> Opened 2026-07-28. Two efforts that were originally planned as one sequenced
> migration, split here into three tracks because they have different risk
> profiles and only one of them was urgent.
>
> Companion docs: [`secrets.md`](secrets.md) (integration model),
> [`vm-disk-weight.md`](vm-disk-weight.md) (measured fleet disk),
> [`vm-disposability.md`](vm-disposability.md) (can we delete a VM?),
> [`exe-dev.md`](exe-dev.md) (SSH discipline, no-hook contract).

## Why this was split into tracks

The original plan coupled integration cleanup to an image migration: replacement
VMs would be built on a slim base and given only the integrations they need, so
capability narrowing would fall out of the migration. That is backwards in one
important way — **six integrations were attached `auto:all`, so every VM the
migration created would inherit them on first boot.** Cleaning `auto:all` is a
prerequisite for migrating, not a product of it.

It also front-loaded a full baseline of the entire fleet before anything could
move, which gated a live security finding behind weeks of survey work.

| Track                   | Scope                                                      | Status                             |
| ----------------------- | ---------------------------------------------------------- | ---------------------------------- |
| **0 — Control plane**   | Agent forwarding, socket persistence, `auto:all` cleanup   | **Done** (except cohort decisions) |
| **1 — Free reclaim**    | `/tmp`, journal, apt; extend `prune-disk` past `$HOME`     | **Done** at 7d (766 MB); 3d open   |
| **2 — Image migration** | Slim dev base; `telnyx-vm` after the number port completes | Blocked on bootstrap               |

---

## Track 0 — control plane

### Finding 1: the exe.dev control key reached every VM (closed)

`ssh iv-docs 'ssh exe.dev whoami'` returned the account identity. Two
independent mechanisms, and the second is the one a naive check misses:

1. **`~/.ssh/config` had a blanket `Host *.ts.net` → `ForwardAgent yes`.**
   `CanonicalizeHostname` rewrites `iv-docs` → `iv-docs.dojo-sun.ts.net`, so
   every tailnet VM received the 1Password agent — and with it the exe.dev
   control-plane key. Confirmed by `SSH_AUTH_SOCK` being set on the VM.

2. **The VM-side config carried `ControlMaster auto` + `ControlPersist 600` for
   `exe.dev`.** Once any control command ran during a session, an
   _authenticated_ socket survived at `~/.ssh/sockets/` for ten minutes,
   reusable by any process running as `exedev` — no key, no agent. Confirmed:
   a second `ssh exe.dev whoami` succeeded with `SSH_AUTH_SOCK` **unset**.
   Only `-o ControlPath=none` produced the correct
   `Permission denied (publickey)`.

Blast radius: those VMs run autonomous agents (Shelley, Claude, Codex) as
`exedev`. Any of them could have run `ssh exe.dev rm <vm>`,
`integrations attach … auto:all`, or `share set-public`.

There was **no standing credential on disk** — no private key, and auth
correctly failed once both mechanisms were suppressed. This was an escalation
window, not a permanent grant.

**Fixed:**

- `install.sh` — `ForwardAgent yes` moved from the blanket `Host *.ts.net` into
  the `klundstedt-mini` block (a trusted Mac we own, so the laptop → mini case
  still works). The exe.dev-VM `Match` block now sets `ForwardAgent no`
  explicitly. First-match-wins makes this precise.
- `install.sh` (Linux branch) — `ControlMaster`/`ControlPath`/`ControlPersist`
  removed from the VM-side `Host exe.dev *.exe.xyz` block. Multiplexing stays
  on macOS, where it is genuinely valuable (exe.dev drops repeated SYNs per
  source IP); on a VM it only buys an escalation window.
- Applied live to this Mac and to all nine tailnet VMs; sockets cleared.

**Verification — the probe must test three states, not one.** A single
`ssh exe.dev whoami` from a VM is nondeterministic: it fails while a socket is
warm and passes eleven minutes later. The correct probe reports the forwarded
agent, the socket count, on-disk private keys, and the result of an attempt
made with `-o ControlPath=none -o ControlMaster=no`.

Result across all ten VMs, 2026-07-28: `denied (good)` everywhere.
`rss-feed` has **no ssh client at all** (exeslim ships without one) — an
unplanned reinforcement of the slim-base security argument.

One incidental find: `iv-entire-agent-shelley` holds a private key
`~/.ssh/id_entire_setup`. Not exe.dev control authority, but it is a key on a
disposable VM and should be accounted for.

### Finding 2: `tailscale-api` was `auto:all` (closed)

```
tailscale-api  http-proxy  target=https://api.tailscale.com  auto:all vm:telnyx-vm
```

Tailnet administration — mint auth keys, remove nodes, edit ACLs — attached to
every VM, and **doubly attached**, so detaching one spec would have left it
live. Demonstrated from `rss-feed`, the internet-facing VM slimmed specifically
to reduce attack surface:

```
tailscale-api proxy -> HTTP 200      # minted an OAuth token
```

**Fixed:** detached from both `auto:all` and `vm:telnyx-vm`. Re-probed:
`HTTP 200` → **`HTTP 403`** from `rss-feed`, `iv-docs`, and `telnyx-vm`. All
nine `tag:dev` peers still `Running` — tailnet connectivity is unaffected,
because `tailscaled` never calls the admin API in steady state. It is needed
only at join time.

`join-tailnet` rewritten to **attach-then-detach**: it checks whether the
integration is already attached (and if so leaves it as found), attaches for the
duration of the join, and detaches via a trap that fires on error and interrupt,
not only on success. Keys remain `ephemeral:true`, so a node that stays offline
is removed and must be re-joined by re-running the script.

`--tag=iv` is no longer sufficient or required for tailnet joining.

### Finding 3: `github-mcp-*` were both `auto:all` (closed)

The deciding fact: the fleet runs **two GitHub accounts** — `kylelundstedt`
(home, plus USAA) and `IndustryVault` / `iv-cmg` (work, per `sync-repos.sh`) —
and **every one of the fleet's 13 GitHub repo integrations is
`repos=kylelundstedt/*`.** Not one VM has an IndustryVault or iv-cmg repo. Yet
`github-mcp-work` was `auto:all`, granting work-org API access to all ten VMs
including the two public ones, with no VM-side consumer.

`secrets.md` already documented these at narrower scopes (`tag:iv` and
`vm:` per VM). Nobody widened them deliberately — **the drift predates this
work**, so narrowing restored documented intent rather than setting new policy.

Decided and applied 2026-07-28:

| Integration       | Was        | Now                          | Rationale                                                                                                                                     |
| ----------------- | ---------- | ---------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| `github-mcp-work` | `auto:all` | **`(none)`**                 | No VM has a work-org repo. Attach per-VM if a work-org task ever lands on one.                                                                |
| `github-mcp-home` | `auto:all` | `tag:iv` + `vm:kgl-thoughts` | Covers every VM where agents do GitHub work; drops public `rss-feed` and `telnyx-vm`. kgl-thoughts is untagged so it needs the direct attach. |

Verified by probe (`404` = attached, proxy forwarded; `403` = not attached):

```
iv-docs        home=404  work=403      (tag:iv)
kgl-thoughts   home=404  work=403      (vm: attach)
telnyx-vm      home=403  work=403      (untagged, public)
rss-feed       home=403  work=403  tailscale-api=403
```

`rss-feed`, the public production VM, now holds zero GitHub and zero Tailscale
authority.

**Detaching an integration orphans its MCP registration.** Seven VMs were left
with a `github-work` MCP server whose endpoint 403s — visible as
`! Needs authentication` in `claude mcp list`, not silent, but noise every
session. Removed from all seven (`claude` + `codex`), and `mcp.manifest`'s
vm-url column set to `-` so a re-provision cannot restore it.

That exposed a **latent bug in the `-` convention itself**. The manifest defines
`-` as "not registered on VMs", but two consumers passed the value through
verbatim rather than skipping the row:

- `iv-image/vendor-skills.sh` emitted `{"url": "-"}` — a server pointing at a
  literal dash, worse than the state it was meant to fix.
- `diff-provisioning.sh` built its expected map the same way, so `want`
  contained `{"github-work": "-"}` while a correct generator omits the key —
  **permanent drift that no amount of re-vendoring could clear.**

Both filters fixed and now match exactly. `diff-provisioning: no drift`.

Still open, and deliberately not actioned — these are judgment calls about
intent, not unambiguous over-grants:

| Integration      | Attachment                                  | Question                                                                                            |
| ---------------- | ------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| `motherduck-mcp` | `tag:iv`                                    | Broad MotherDuck to everything tagged `iv`. Narrow to a cohort?                                     |
| `llm`            | `tag:llm` **+** `auto:all`                  | `auto:all` wins; the tag attachment is dead weight. Keep as a deliberate global default, or narrow? |
| `telnyx-test`    | `vm:iv-home` + `vm:telnyx-vm`               | Why does `iv-home` have Telnyx? Probably a stray.                                                   |
| `fannie-token`   | `tag:fannie-token` + `vm:iv-foundry-stage2` | **The tag attachment is dead** — no VM carries that tag. Only the `vm:` attach is live.             |

Found incidentally: **`kgl-thoughts` has a dead `motherduck` MCP registration.**
`motherduck-mcp` is `tag:iv` and `kgl-thoughts` is untagged, so that server has
been failing since before this work. Left alone — the fix is either attaching
the integration or dropping the registration, and that is a question about what
the blog VM is for.

Correctly clean already and worth preserving as the pattern:
`github-kylelundstedt-dotfiles-writer`, `github-kylelundstedt-iv-image-writer`,
and `github-kylelundstedt-rss-feed` all sit at `(none)` — dormant write
authority, attached only when used.

**Lesson from `fannie-token`: tag-based attachment drifts silently.** A tag
attachment whose tag no VM carries looks live in `integrations list` and grants
nothing. Prefer `vm:` for singleton authority; reserve tags for genuine cohorts.

---

## Track 1 — free reclaim (done 2026-07-28, partially)

Measured on `iv-docs`, 11 GB used:

| Path              |      Size | Owner                                   |
| ----------------- | --------: | --------------------------------------- |
| `/usr`            |     4.3 G | base image + `/usr/local` 1.5 G (ours)  |
| `/home`           |     3.4 G | our overlay + work                      |
| **`/tmp`**        | **1.6 G** | mixed — **not scratch**, see below      |
| `/headless-shell` |     252 M | **in use by Shelley — not reclaimable** |
| `/opt`, `/var`    |     649 M | mixed                                   |

**Correction to the initial survey: `/headless-shell` is not dead weight.** It
was listed as "exeuntu Chrome" and assumed unused. On `iv-docs` it has three
running processes and is referenced from `/etc/systemd/system/shelley.service`
and `shelley.db` — removing it would break Shelley's browser capability. That is
2.25 GB across the fleet that stays.

**`/tmp` is not scratch either.** It holds git repos with local-only commits,
including nine on `iv-docs` against a vendor repo we cannot push to. Full
finding and its consequence for the disposability invariant:
[`vm-disposability.md`](vm-disposability.md) → "Correction — v3's zero unpushed
work was scoped to `$HOME`".

`prune-disk` gained `--system` (Linux, opt-in, needs sudo): `/tmp` entries older
than `--tmp-age` days, systemd journal vacuumed to `--journal-cap`, and apt's
`.deb` cache. Guard 3 protects any `/tmp` entry containing a repo with a real
remote and unpushed commits; remote-less and local-path clones count as scratch,
which is what keeps the rule useful — pytest fixtures alone were 920 MB.

Applied at `--tmp-age 7` across all nine VMs: **766 MB actually reclaimed.**

The planned figure was 4.1 GB, and the difference is honest rather than a
failure: the cache lines are labelled upper bounds because `uv cache prune`
keeps live entries, so most of that was never free. What genuinely moved was the
journal (`iv-docs` 106 M → 64 M) and old `/tmp` (`kgl-thoughts` 195 M → 31 M).

Then approved and applied at `--tmp-age 3`, catching the large consumers that
were 3–4 days old: **a further 1.78 GB** (`iv-gitlake-examples` 1.42 G of
generated TPC-H data, `iv-docs` 329 MB of pytest fixtures, `kgl-thoughts`
30 MB). What remains in `/tmp` is all newer than 3 days and in active use.

**Track 1 total: ~7.8 GB.** Fleet instantaneous total 68.9 G across ten VMs.

### Guard 3 had to be corrected before the 3-day run

The 7-day pass reported five `/tmp` entries holding "local-only" commits,
headlined by `/tmp/shelley-review` with 9 against `boldsoftware/shelley` — a
vendor repo we cannot push to. **All of them were false positives**; every
commit was verified present upstream. Two faults, both in the audit's own
predicate:

- **`--all` includes `refs/tags`, while `--not --remotes` subtracts only remote
  _branches_.** An upstream tag pointing at a commit on no remote branch reads
  as local work. `shelley-review` has 644 tags and all 9 commits hung off the
  upstream tag `v0.670.946516660`.
- **Stale remote-tracking refs** report pushed commits as unpushed.

Guard 3 now uses `rev-list --branches HEAD --not --remotes`. Both faults
over-report, never under-report, so no data was ever at risk and the earlier
`$HOME` audit conclusion is unaffected. Full write-up:
[`vm-disposability.md`](vm-disposability.md) → "`/tmp` was a scope gap".

Base-image junk, quantified for the Track 2 case: `snapd` 103 M (`/snap` is
empty), `pocketsphinx` 37 M (speech recognition), `icons` 47 M, `fonts` 39 M,
`doc` 55 M, `man` 39 M.

Still unscheduled: nothing runs `prune-disk` periodically, so the Claude
versions directory and these caches regrow. Settle it alongside the
AgentsView retention timer (see `TODO.md`).

## Track 2 — image migration (blocked)

Current pooled usage: **81.4 / 100 GB**, `Individual Plan (Small)`, measured as
filesystem usage averaged over the cycle.

`rss-feed` is **already migrated** — `kylelundstedt/exeslim:2026-07-28.1.1`,
7.8 GB → 268 MB, feed output byte-identical. Any plan that lists it as a pilot
target is working from a stale baseline.

**Realistic dev-VM saving is ~1.5–2 GB each, not the 7.5 GB `rss-feed` saw.** A
dev VM still needs git, Python, Node, and build tools, and `/usr/local` at
1.5 GB is ours — a slim base does not touch it. Roughly 8 × 2 GB ≈ 16 GB, which
is worth doing on an 81/100 budget, but the case should rest on that number and
not on analogy to `rss-feed`.

**Blocker:** `provision-iv.sh` assumes stock exeuntu and opens with a
`git clone` — a bare base has neither git nor a GitHub credential. Self-
bootstrapping it is the prerequisite, and the reason the dev lane has not moved.

**`telnyx-vm` is the worst available pilot and should be deferred.** It is
mid-port — actively moving work and personal numbers from Zoom to Telnyx, an
irreversible external process on carrier timelines — is `public_proxy: true`
because Telnyx posts webhooks to it, holds `/etc/telnyx-webhook.env` outside
`$HOME`, and carries zero tags. Migrate after the port completes.

### Two migration lanes, not one ritual

[`vm-disposability.md`](vm-disposability.md) established that the fleet holds
zero unpushed work and all state lives in git and Tigris. For dev VMs the
correct migration is therefore **delete and recreate**, with "the repo clones
and the toolchain installs" as the acceptance test. Reserve full side-by-side
acceptance, a rollback window, and staged retirement for the two VMs that have
external dependencies on their identity:

- `kgl-thoughts` — custom domains `lundstedt.us`, `www.lundstedt.us`
- `telnyx-vm` — Telnyx webhook endpoint, mid-port

### Replacement VMs must be re-enrolled in fleet services

Missing from the original plan, and all three are fail-closed, so a replacement
will page you:

- **AgentsView** source enrollment — a systemd **user** unit, bearer token, and
  a `[[remote_hosts]]` entry in the collector config
- **Entire** checkpoint push status
- **healthchecks.io** registration (`provisioning/checks.manifest`)

Add temporary VM names to `provisioning/agentsview-coverage-exclude.txt` for the
migration window; that mechanism already exists.

### Probe gotchas that have now bitten twice

- Non-interactive SSH `PATH` on these VMs is
  `/bin:/usr/bin:/sbin:/usr/sbin:/exe.dev/bin:/usr/local/bin` — **no
  `~/.local/bin`**, so `command -v <tool>` false-negatives.
- AgentsView's unit is a **user** unit, so `systemctl is-active` without
  `--user` false-negatives.
- `grep -c … || echo 0` prints `0\n0` when there is no match (grep exits 1 and
  the fallback also fires). Drop the fallback.
- `sed` address delimiters need `\|…|`, not `|…|`. An invalid expression makes
  the whole `-e` set a silent no-op — it looked like the edit applied.

## Two more traps, both about work that looks applied and isn't

**`ControlMaster` masks broken auth on the Mac too, not just on VMs.** Every
`ssh exe.dev` this session rode a single control master opened by the first
call. When it aged out at `ControlPersist 600`, commands started failing
`Permission denied (publickey)` — 1Password was locked, so the agent could
**list** the exe.dev key but not **sign** with it. Mac-side authentication had
been broken for some time and multiplexing hid it, which is the same masking
effect this document records as the escalation window on the VMs, seen from the
other side.

Diagnose locally without touching exe.dev — this distinguishes a locked agent
from a config or rate-limit problem in one command:

```bash
ssh-add -l                        # lists keys even when locked — proves nothing
ssh-add -T ~/.ssh/exe_dev.pub     # actually signs; "communication with agent failed" = locked
```

**Editing a skill in this repo does not deploy it.** `agents/.stow-local-ignore`
excludes `.agents/skills` on purpose — "deployed by `npx -y skills add` (not
stowed) to avoid multi-level symlinks that Codex can't resolve". So
`agents/.agents/skills/<name>/` is the **source**, and `~/.agents/skills/<name>/`
holds real files installed **from GitHub**, per `provisioning/skills.manifest`.

The `join-tailnet` fix above was inert until it was committed, pushed, and then
reinstalled:

```bash
npx -y skills add -g -y kylelundstedt/dotfiles -s sprites-dev join-tailnet upgrade-vm
diff ~/.agents/skills/join-tailnet/SKILL.md agents/.agents/skills/join-tailnet/SKILL.md
```

The live copy was three weeks stale and nothing warned. Verify with `diff`
after editing any skill. Note `upgrade-vm` fails to install
("PromptScript does not support global skill installation") — pre-existing, and
`herdr` fails the same way.

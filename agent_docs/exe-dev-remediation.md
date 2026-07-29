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

| Track                       | Scope                                                       | Status                                    |
| --------------------------- | ----------------------------------------------------------- | ----------------------------------------- |
| **0 — Control plane**       | Agent forwarding, socket persistence, `auto:all` cleanup    | **Done**                                  |
| **1 — Free reclaim**        | `/tmp`, journal, apt, pip; extend `prune-disk` past `$HOME` | **Done** — ~7.8 GB, fleet 68.9 G          |
| **2a — Trim our own layer** | aws on-demand, de-duplicate, drop `pi`                      | **Done** — ~6.0 GB, fleet 63.1 G          |
| **2b — Slim dev base**      | exeslim-dev image, Shelley units, canary-proven             | **Proven** — 276 MB fresh; not adopted    |
| **3 — Recreate cycle**      | `new-dev-vm` automates create + full re-enrollment          | Script written; **never completed a run** |

## Status against the original A/B/C/D plan (2026-07-29, end of session)

**Integration cleanup: complete.** These were in-place and reversible, so A→D
collapsed into one pass rather than needing staged replacement. `auto:all` went
6 → 3 (`llm`, `notify`, `reflection`). The control-plane escalation is closed
and verified `denied` on all ten VMs.

**Disk slimming: Phase A and B done, C and D not started.**

- **A (baseline):** done. Fleet ~81 → **63 GB** via Tracks 1 and 2a.
- **B (build + validate a replacement):** done. exeslim-dev built, published and
  canary-proven — 276 MB, Shelley socket-activated on 127.0.0.1:9999,
  `provision-iv.sh` in 50 s, 0 failed units.
- **C (cutover):** **not started.** No existing VM has been recreated.
- **D (retirement):** not started. Nothing deleted.

**Nothing is half-cut-over.** The only changes to live VMs were integration
detachments (each verified non-breaking) and removal of packages measured
unused. No VM was recreated, renamed, or repointed.

**`telnyx-vm` is deliberately excluded from all of it** — mid-port, irreversible
carrier process, registered webhook endpoint. Its only change was dropping a
redundant `tailscale-api` attachment; `telnyx-test` was kept and verified live
read-only (`/v2/messaging_profiles` → 200, `/v2/phone_numbers` → 200 with 2
numbers, webhook active on :8000). It stays on exeuntu and is not a cycle
candidate.

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

### Finding 4: the remaining four attachments (closed 2026-07-28)

| Integration      | Was                                         | Now                        | Why                                                                                                                                                   |
| ---------------- | ------------------------------------------- | -------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| `motherduck-api` | `tag:motherduck-api` (3 VMs)                | **`(none)`**               | Same target and auth type as `motherduck-mcp`, referenced by no config, and in no manifest. See the caveat below.                                     |
| `llm`            | `tag:llm` **+** `auto:all`                  | `auto:all`                 | `auto:all` already covered every VM, so the tag granted nothing. Kept as a deliberate global default.                                                 |
| `telnyx-test`    | `vm:iv-home` + `vm:telnyx-vm`               | **`vm:telnyx-vm`**         | `iv-home` was a stray — Telnyx appeared only in its `shelley.db` chat history, and it has no telephony work.                                          |
| `fannie-token`   | `tag:fannie-token` + `vm:iv-foundry-stage2` | **`vm:iv-foundry-stage2`** | The tag attachment was dead: no VM carries `tag:fannie-token`. The `vm:` attach is live and **must stay** — it is how M3 downloads fannie-sflpd data. |

**403 does not mean "not attached", and this nearly misled the audit.**
`fannie-token` on `iv-foundry-stage2` returns HTTP 403, but it is attached:
reflection lists it and the control plane shows `vm:iv-foundry-stage2`. The 403
comes from Fannie's own SSO, which does not work yet — an upstream problem, not
an attachment one. exe.dev also returns 403 for an unattached integration, so
the code alone cannot distinguish the two. Verify with the reflection endpoint
cross-checked against `integrations list`; every conclusion in this document was
re-verified that way.

**`telnyx-vm`'s capability was verified intact afterwards, not assumed.** It is
the one VM running an irreversible external process, so a read-only check
through the proxy (no traffic, no charges):

```
GET /v2/messaging_profiles -> HTTP 200   (1 profile)
GET /v2/phone_numbers      -> HTTP 200   (2 numbers on account)
telnyx-webhook: active, listening on :8000
```

**Caveat on `motherduck-api`, worth keeping.** It was not pure drift — it came
from the local-DuckDB-vs-MotherDuck comparison work. Two things make the detach
safe:

- `iv-gitlake-examples`, where the `tpch-mortgage` benchmark data actually
  lives, **never had `motherduck-api` attached** — it carries only `tag:iv`, so
  that comparison was always running through `motherduck-mcp`.
- `motherduck-mcp` reports `✔ Connected` on both `iv-docs` and
  `iv-gitlake-examples`, which is a real authenticated handshake.

What could not be verified is whether the two carry **different tokens**. Both
target `api.motherduck.com` with a Bearer and returned byte-identical responses
on every path tried, but token values are server-side. If `motherduck-api` was
scoped to a different MotherDuck org or database, that access is now gone —
restore with `integrations attach motherduck-api tag:motherduck-api`. The
integration is still defined and `tag:motherduck-api` is still on the three VMs;
**those tags were deliberately left in place as the restore path** rather than
tidied away.

Also fixed: **`kgl-thoughts` had a dead `motherduck` MCP registration** —
`motherduck-mcp` is `tag:iv` and `kgl-thoughts` is untagged, so it reported
`! Needs authentication` every session, from before this work. Registration
removed (claude + codex); re-add if the blog VM ever needs MotherDuck.

### Resulting `auto:all` set

Six integrations were `auto:all` at the start. Three remain, and they are
exactly the ones the target model called legitimate global defaults:

```
llm         auto:all
notify      auto:all
reflection  auto:all
```

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

## Track 2a — trim our own layer (done 2026-07-28)

The base-image question turned out to be the _smaller_ half. Measured on the
fleet, our own two layers carried ~6 GB of tooling nobody used.

| Change                                    |       Freed | Evidence                                                              |
| ----------------------------------------- | ----------: | --------------------------------------------------------------------- |
| `aws` → on-demand `install-cloud-cli aws` |  **2.9 GB** | 267–533 MB/VM and **not one VM had `~/.aws/config` or credentials**   |
| De-duplicate shadowed binaries            |  **2.0 GB** | `codex`/`uv`/`claude` installed by _both_ the base image and dotfiles |
| Drop `pi` (unused)                        | **1.09 GB** | 116–124 MB/VM                                                         |

Fleet went 68.9 G → **63.1 G**. (The billing gauge is a cycle _average_, so it
lags; do not compare it to an instantaneous total.)

### aws was an inconsistency, not a decision

`install-cloud-cli`'s own header already stated the rule for azure and gcloud —
"Most VMs never touch Azure or GCP, so they install per-VM, on demand". aws was
simply exempt from it. The S3 work here targets Tigris over S3-compatible
endpoints via the `tigris` CLI, boto3 and duckdb httpfs; the `s3://` and `boto3`
references in `ave-adapters` are Tigris, not AWS.

A second, quieter bug surfaced: `aws/install --update` leaves the superseded
version under `/usr/local/aws-cli/v2/`, so VMs provisioned more than once
carried **two** copies — hence 533 MB on four VMs against 267 MB on three. The
round trip was verified before trusting it: install (sha256-verified) → correct
version → idempotent re-run → clean removal.

### The duplication is caused by the base image, and 2b removes it at the root

The shadowed copies came from **exeuntu**, not from `iv-image`. Timestamps on
`iv-docs` (VM created 2026-06-16):

```
/usr/local/bin/codex  2026-06-15   base image     0.140.0   <- stale, shadowed
~/.local/bin/codex    2026-07-16   dotfiles       0.144.5   <- PATH winner
/usr/local/bin/uv     2026-06-11   base image     0.11.21   <- stale, shadowed
~/.local/bin/uv       2026-07-15   dotfiles       0.11.29   <- PATH winner
```

So the wasted bytes were the **base's**, frozen at whatever Canonical's rebuild
shipped, silently shadowed by dotfiles' current copies. Resolution applied in
both directions: dotfiles owns the agent CLIs and `uv` (it keeps them current,
and they are per-user authenticated tools that belong in `~/.local/bin`); the
team layer owns shared data tooling (`duckdb`, `tigris`, `herdr`, …), where
dotfiles' `want()` already refuses to install on IV VMs via
`provisioning/tools.manifest` team rows — so the fix is durable without a code
change.

**This is a symptom of the base, not a design flaw in our layers.** On a base we
control we simply do not ship agent CLIs, and there is exactly one copy by
construction — nothing to de-duplicate, no stale shadow, no PATH-order coin
flip. That is an argument _for_ 2b, independent of bytes.

`/usr/local/go` (269 MB/VM) is likewise base-image — dated before VM creation,
owned by no dpkg package — so it cannot be moved to on-demand by
`provision-iv.sh`. It is a 2b item.

## Track 2b — slim dev base

### Sizing, stated plainly

The image is **small**; the saving is what is large. This was miscommunicated
twice, so in a table:

|                              |        Size |
| ---------------------------- | ----------: |
| exeuntu (today's base)       |       ~4 GB |
| exeslim                      |      175 MB |
| + `git`, `uv`, `jq`, `unzip` | ~250–300 MB |
| **Stopped carrying, per VM** | **~3.7 GB** |

`provision-iv.sh` needs `git`, `jq` and `unzip`, which exeslim does not ship
(`tar` is already essential; the `node` reference is only an echo). `git` is
also needed to clone `iv-image` in the first place.

### The premise that blocked this was wrong

`iv-image` stated that a custom image "silently disables Shelley", which is why
the fleet stayed on stock exeuntu. exe.dev documents an opt-in label
(`ssh exe.dev doc customization`):

> `LABEL exe.dev/install-shelley=true` makes exe.dev automatically install a
> recent Shelley in `/usr/local/bin` on creation and makes the UI assume that
> Shelley is installed.

Corrected in `iv-image` (`a107dcc`). **Not yet tested by us** — documentation
evidence only. Our one exeslim VM (`rss-feed`) was built without the label, so
it confirms the default-off behaviour and nothing about the opt-in.

### Canary results — 2026-07-29, two VMs, both since deleted

Everything below was measured on `canary-slimdev` and `canary-shelleyunit`, not
predicted.

| Check                                         | Result                                                                                 |
| --------------------------------------------- | -------------------------------------------------------------------------------------- |
| Fresh VM                                      | **276 MB** (vs exeuntu ~4 GB)                                                          |
| + `provision-iv.sh` (35 skills, lock written) | 1.1 GB, **50 s**                                                                       |
| + dotfiles overlay (no agent CLIs)            | 2.2 GB                                                                                 |
| Failed units                                  | 0                                                                                      |
| linger / `/run/user/1000`                     | present — AgentsView's user-unit prerequisite holds                                    |
| `/exe.dev/etc/image.conf`                     | **present**, and the lock file recorded this repo's commit sha, so provenance survives |
| `/headless-shell`                             | **absent** (Shelley's browser, 252 MB on exeuntu)                                      |
| `EXEUNTU=1`                                   | absent, as expected                                                                    |

Three defects surfaced that no amount of reading would have found:

1. **`provision-iv.sh` aborted silently.** A guarded `systemctl --user disable`
   followed by an **unguarded** `daemon-reload`, under `set -e`. Provisioning
   died after installing every binary but before the agent config, MCP servers,
   skills and the lock file — a box that looked provisioned, with 0 skills.
   Latent on any first provision where the user manager has no bus address.
   Fixed in `iv-image` (`aac5044`) with a `uctl` wrapper.
2. **`apex` needs `libyaml-0.so.2`**, absent from exeslim. Checksum passed, then
   the binary failed to load. An `ldd` sweep confirmed apex is the only affected
   binary, so it is the whole gap.
3. **`DBUS_SESSION_BUS_ADDRESS`** is an image `ENV` on exeuntu and unset on
   exeslim. Every `systemctl --user` call failed despite an active user manager,
   linger set and `/run/user/1000/bus` existing — socket present, client had no
   address for it. That one variable caused defect 1 to fire.

### Shelley: the label installs it, the image must run it

`LABEL exe.dev/install-shelley=true` does exactly what the docs say — installs
the binary to `/usr/local/bin` and makes the UI assume Shelley is present. It
does **not** run it, and creates no unit: nothing under `/etc/systemd`,
`/run/systemd`, `/usr/lib/systemd` or `/exe.dev`. exeuntu ships its own
`shelley.socket`/`shelley.service`; a custom image needs equivalents.

Ours are written against `shelley serve -h` — `-systemd-activation`,
`-require-header`, `-db`, `-config` are all documented flags — rather than
copied from exeuntu, so they stay maintainable when exe.dev ships a new Shelley.

**Socket activation is load-bearing, not stylistic.** `shelley serve -port 9999`
binds `*:9999` (measured), and these VMs sit behind a public HTTPS proxy.
Letting systemd own the bind keeps it on `127.0.0.1:9999`. Verified on
`canary-shelleyunit`:

```
shelley.socket   enabled, active
shelley.service  inactive        <- correct: socket-activated
listener         127.0.0.1:9999  <- loopback, not *:9999
request          HTTP 200 -> shelley.service became active
failed units     0
```

### Quarto — corrected, and where it actually goes

An earlier estimate here claimed ~2.5 GB from making Quarto on-demand. **That
was wrong and was written without checking usage.** Five of six VMs have a real
site with `_site/` build output and had run the binary within the week.

What is true: **no site uses Quarto's computational features** — no r/python/
julia/ojs blocks anywhere. Quarto is a 423 MB static site generator for plain
markdown, which is indefensible on size but not removable by deletion.

So `provision-iv.sh` now installs Quarto only where a `_quarto.yml` exists
(`IV_QUARTO=1` forces it) — fresh VMs stop carrying it; existing sites keep it.

The real replacement, given the requirement "render the markdown docs and follow
the existing git repo structure": **not** mdBook (wants `SUMMARY.md`), Hugo or
Zola (want their own `content/` layout) — all would fight the repo structure.
Two candidates that follow it, both measured on the canary against a real doc
with a GFM table, code fences and YAML frontmatter:

| Tool      |       Size | Notes                                                                                                                                                                  |
| --------- | ---------: | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `lowdown` | **268 KB** | In Ubuntu 24.04 (`1.1.0-1`), so apt owns updates — no pin, no checksum, no supply chain of our own. Consumed frontmatter into `<title>`, rendered table + fences, rc=0 |
| `apex`    |     1.2 MB | Already installed and pinned by `provision-iv.sh`; also does `-t gfm` normalisation and terminal output                                                                |
| Quarto    |     423 MB | ~1,500x larger than either                                                                                                                                             |

The renderer is the easy part; the work is a walk script that mirrors the repo
tree, rewrites `.md` links to `.html`, and applies include/exclude globs (which
is all `_quarto-internal.yml` / `_quarto-product.yml` are). The `.md` twins are
free — the sources are already markdown — and `gen-llms-txt.py` is already
standalone. What is lost is Quarto's built-in search — tracked in `TODO.md`, and possibly
not worth building. These sites already co-emit `format: gfm` markdown twins
and an `llms.txt` index expressly "so AI agents can consume the site as
markdown rather than HTML" (iv-docs `_quarto.yml`), so the primary consumer may
be agents rather than browsers. An **IV MCP server** over that markdown would
serve them directly and reduce in-page search to a human-only nicety. Decide
that before writing a JSON index and JS.

Do it on `gitlake` or `ave-adapters` first. `iv-docs` is 126 pages across 3
profiles with a post-render pipeline and is client-facing; it goes last.

### Remaining trim candidates, verified as unconfigured

Same test that settled aws — is it actually configured, rather than merely
present:

```
rclone   no ~/.config/rclone/rclone.conf   on any VM
tigris   no config                          on any VM
gh       `gh auth status` fails             on any VM
```

~206 MB/VM. `carapace` (78 MB) is **not** a candidate — it genuinely runs on
every shell for completions. Note `install.sh`'s `GITHUB_TOKEN=$(gh auth token)`
is a no-op on VMs as a result.

### Original gating checklist (all now answered)

One throwaway canary answers everything: does `shelley_url` appear, does the UI
button appear, does Shelley _run_ on a base lacking git, does `/headless-shell`
(Shelley's browser, 252 MB) come along, and is `git`/`jq`/`unzip` enough for
`provision-iv.sh`.

**AgentsView and Entire do not belong in the image** — `provision-iv.sh` installs
`agentsview` (pinned) and `install.sh` installs `entire`, both volatile, so the
same rule that keeps duckdb and quarto in the scripts applies. What the image
owes them is prerequisites, and AgentsView has a real one: its source daemon is a
**systemd user unit**, needing `dbus-user-session` and `loginctl enable-linger`
to survive logout. exeslim ships systemd + dbus-user-session, so it should work —
which is precisely why the canary must confirm it rather than assume. Same for
`tailscaled`: exeuntu ships it, exeslim does not, and `install.sh` installs it on
Linux — but AgentsView binds the tailnet IP, so the ordering has to hold. Also record that a custom image is not recognised as
"exeuntu", so `EXEUNTU=1` and the `/exe.dev/etc/image.conf` labels the lock file
reads are absent, and that Shelley credits on a custom image are unverified.

### What stays a script, and why

exe.dev **fixes a VM's image at creation and offers no way to move a live VM
onto a newer one** — `new`, `rm`, `restart`, `cp`, `resize`, and `cp` clones the
disk you already have. Baking the version-pinned tools would turn every bump
into a fleet recreate, against today's in-place ~23 s re-run. And baking saves
nothing: usage is each VM's own ext4 with no cross-VM dedup, so moving a binary
into an image layer relocates bytes rather than removing them.

Disposability makes recreate _acceptable_, not _free_ — the cost is
re-enrollment (tailnet, AgentsView token + collector config, integrations,
healthchecks), which is the real adoption blocker and wants a scripted bring-up.

## Track 2 — original notes (superseded by 2a/2b above)

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

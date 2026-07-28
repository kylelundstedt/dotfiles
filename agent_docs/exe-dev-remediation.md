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

| Track                   | Scope                                                              | Status                             |
| ----------------------- | ------------------------------------------------------------------ | ---------------------------------- |
| **0 — Control plane**   | Agent forwarding, socket persistence, `auto:all` cleanup           | **Done** (except cohort decisions) |
| **1 — Free reclaim**    | `/tmp`, `/headless-shell`, snapd; extend `prune-disk` past `$HOME` | Not started                        |
| **2 — Image migration** | Slim dev base; `telnyx-vm` after the number port completes         | Blocked on bootstrap               |

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

### Open decisions — `auto:all` and broad attachments

These were **not** actioned, because they are judgment calls about intent rather
than unambiguous over-grants.

| Integration       | Attachment                                  | Question                                                                                                       |
| ----------------- | ------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| `github-mcp-home` | `auto:all`                                  | Live MCP server on `iv-docs`, `iv-home`, `kgl-thoughts`. Which VMs are the personal cohort?                    |
| `github-mcp-work` | `auto:all`                                  | Live on `iv-docs`, `iv-home`, `iv-foundry-stage2`, `kgl-thoughts`. Does the personal blog VM need work GitHub? |
| `motherduck-mcp`  | `tag:iv`                                    | Broad MotherDuck to everything tagged `iv`. Narrow to a cohort?                                                |
| `llm`             | `tag:llm` **+** `auto:all`                  | `auto:all` wins; the tag attachment is dead weight. Keep as a deliberate global default, or narrow?            |
| `telnyx-test`     | `vm:iv-home` + `vm:telnyx-vm`               | Why does `iv-home` have Telnyx? Probably a stray.                                                              |
| `fannie-token`    | `tag:fannie-token` + `vm:iv-foundry-stage2` | **The tag attachment is dead** — no VM carries that tag. Only the `vm:` attach is live.                        |

Verified consumers, so a blind detach would break agent MCP:

```
iv-docs            github-mcp-home  github-mcp-work  llm  motherduck-mcp
iv-home            github-mcp-home  github-mcp-work  llm  motherduck-mcp
iv-foundry-stage2                   github-mcp-work  llm  motherduck-mcp
kgl-thoughts       github-mcp-home  github-mcp-work  llm  motherduck-mcp
```

Correctly clean already and worth preserving as the pattern:
`github-kylelundstedt-dotfiles-writer`, `github-kylelundstedt-iv-image-writer`,
and `github-kylelundstedt-rss-feed` all sit at `(none)` — dormant write
authority, attached only when used.

**Lesson from `fannie-token`: tag-based attachment drifts silently.** A tag
attachment whose tag no VM carries looks live in `integrations list` and grants
nothing. Prefer `vm:` for singleton authority; reserve tags for genuine cohorts.

---

## Track 1 — free reclaim (not started)

Measured on `iv-docs`, 11 GB used:

| Path              |      Size | Owner                                  |
| ----------------- | --------: | -------------------------------------- |
| `/usr`            |     4.3 G | base image + `/usr/local` 1.5 G (ours) |
| `/home`           |     3.4 G | our overlay + work                     |
| **`/tmp`**        | **1.6 G** | **nobody**                             |
| `/headless-shell` |     252 M | exeuntu Chrome                         |
| `/opt`, `/var`    |     649 M | mixed                                  |

**`prune-disk` only walks `$HOME`** — the same blind spot the disposability
audit had until v3, now hit for the third time. `/tmp` alone is 1.6 GB on one
VM, with nothing pruning it. Extend `prune-disk` past `$HOME` and re-run the
fan-out; this is free and needs no migration.

Base-image junk, quantified for the Track 2 case: `snapd` 103 M (`/snap` is
empty), `pocketsphinx` 37 M (speech recognition), `icons` 47 M, `fonts` 39 M,
`doc` 55 M, `man` 39 M.

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

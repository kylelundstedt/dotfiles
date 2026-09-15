# Service placement

Two separate placement questions live here:

1. **Mini service: AC appliance VM or the host?** — the original 2026-07-21
   criterion, below.
2. **Fleet job: which host runs a scheduled probe?** — added 2026-09-15, see
   [Fleet job placement](#fleet-job-placement).

## Mini service — AC appliance VM vs. host

> Decision criterion recorded 2026-07-21, when deciding whether personal-mcp
> should follow llm-gateway into an Apple Container appliance VM (answer: no).
>
> Note: `llm-gateway`, the worked example that motivated this rule, was itself
> **decommissioned 2026-07-22** ([CHANGELOG.md](../CHANGELOG.md)) — for policy
> reasons unrelated to placement. The criterion below is unaffected and stands
> as general guidance; treat the llm-gateway references as an illustrative case,
> not a running service.

## The rule

A mini service is a candidate for the AC-appliance pattern (own exeuntu VM,
own tailnet node, own repo — see [llm-gateway-migration.md](llm-gateway-migration.md))
**only when everything it needs can live inside the VM**: code, config, and —
critically — its secrets or sensitive data. If the service's crown jewels
must stay on the host, containerizing the service punches a hole through the
isolation boundary instead of creating one.

Distinguish two shapes:

- **Appliance** — self-contained, portable secrets, no host data or macOS-API
  dependencies. Containerize. The VM _moves the sensitive asset inside_ and
  isolation is a real gain.
- **Host-integrated service** — inseparable from host-resident data, macOS
  APIs (TCC/Full Disk Access), or local ML runtime. Keep it on the host.
  Containerizing only part of it adds fragility for near-zero isolation gain.

## The two cases that set the precedent

**llm-gateway → appliance (migrating).** A token-custody service: the crown
jewels are subscription OAuth token files, and the migration physically moves
them into the isolated guest. One binary, one config, `--home-mount none` —
nothing left behind on the host.

**personal-mcp → host-integrated (stays put).** Three disqualifiers:

1. **The crown jewels can't move.** The sensitive asset is `~/archives`
   itself (email/iMessage/calendar archives). A VM-hosted server would need
   that data mounted in — a hole through the boundary, not a boundary.
2. **Half the system is macOS-bound.** Ingest reads the Messages `chat.db`
   (TCC/Full Disk Access — host-only) and computes embeddings via LM Studio
   (Metal, a macOS app). Only the serve half could move, leaving a split
   brain: host LaunchAgents writing `~/archives`, a guest reading the same
   DuckDB files over virtiofs — including across `rebuild-hub`'s nightly
   atomic swap of `hub.duckdb`. New failure modes the all-host design lacks.
3. **The gains are thin.** A dedicated node name is cosmetic; the one real
   friction (hub-mcp holding `:443`, pushing llm-gateway to `:8443`)
   disappears once llm-gateway gets its own node. personal-mcp already has
   what the migration buys — own repo, own lifecycle (`bootstrap.sh` +
   launchd), tailnet-only exposure, healthchecks monitoring.

## Also weigh

Every additional AC VM joins the host-fragility drift class documented in
[llm-gateway-migration.md](llm-gateway-migration.md) (FileVault pre-boot
halt, ADP/TCC grant revocation on cask upgrades, boot races). The marginal
VM is not free even when the architecture fits.

## Fleet job placement

> Decision criterion recorded 2026-09-15, after `entire-push-check` spent three
> weeks failing every scheduled run on the mini for a reason that placement, not
> code, was the right fix for.

### The rule

**A probe runs where its inputs already are. Alerting stays off-box.**

Those are two decisions, and conflating them is the trap. "Should monitoring move
to a VM?" sounds like one question and is really two:

- **Where the probe runs** is determined by what it needs to read. A check that
  needs the exe.dev inventory belongs on a host with control-plane access. A
  check that needs the mini's disks belongs on the mini. There is no general
  answer, only a per-input one.
- **Where the dead-man's switch lives** has exactly one answer: somewhere that
  does not share fate with the host being watched. That is what healthchecks.io
  is for, and it is why it should not be self-hosted here. A VM watching the mini
  works until you ask what watches the VM — the honest answers are mutual
  watching (both down = silence) or a third party, i.e. back where you started.
  Delivery matters too: healthchecks.io emails, and any self-hosted replacement
  inherits the mail problem that `monitoring-digest` deliberately declines to
  solve.

### Worked cases

| Job                                    | Inputs it must read                | Runs on                 | Why                                                                          |
| -------------------------------------- | ---------------------------------- | ----------------------- | ---------------------------------------------------------------------------- |
| `tigris-backup`, `msgvault-backup`     | the mini's disks + OWC8TB          | **mini**                | The data is there. See below.                                                |
| `entire-push-check`                    | exe.dev inventory + fleet git refs | **iv-provision**        | Control-plane host; integration supplies the inventory with no SSH key       |
| `agentsview-coverage`                  | exe.dev inventory + tailnet peers  | **iv-agentsview**       | Set this precedent 2026-09-15                                                |
| `monitoring-meta`, `monitoring-digest` | the healthchecks.io API            | **mini**                | Inputs are a public API, so placement is free; the mini is simply convenient |
| `restore-drill`                        | Tigris only                        | **should move to a VM** | See below                                                                    |

### Why backups cannot move off the mini

This gets asked because the mini is a single point of failure, but the constraint
is physical. The data is ~133 GB of Documents, ~44 GB of archives and ~1 TB on
the OWC8TB, all on the mini. A VM would have to pull it over the tailnet and push
it to Tigris: two hops instead of one, the mini's uplink still the bottleneck,
nothing stageable on a 2–3 GB exeslim disk, and the loss of local access
semantics (TCC, the Photos library, iCloud materialisation). Strictly worse on
every axis.

### Why the restore drill should

`backup/restore-drill.sh` is read-only on Tigris. Running it from a VM proves the
backup is restorable **somewhere other than the machine that made it** — the
property you actually want from a backup, and the one a same-host drill cannot
establish. One caveat: its integrity step compares restored content against the
live local source, so either that step stays on the mini or it needs a different
oracle (the msgvault backup repo is self-verifying by content hash and would
serve).

### The cost side

Each VM-hosted job adds a deployment surface: a `provisioning/<vm>/` directory,
systemd units, a `deploy.sh`, and one more place a ping URL lives. That path is
paved (`iv-agentsview`, then `iv-provision`) but it is not free, and it is a
reason to move a probe only when placement fixes something real. For
`entire-push-check` it eliminated a dependency on an interactive app's unlock
state; for a job whose inputs are a public API, it would buy nothing.

### What this does not solve

The mini still hosts 14 of 16 checks, so if it goes down they all go silent at
once and the alert wall cannot distinguish "mini is off" from "fourteen things
broke". A small VM-side liveness probe — mini reachable, disks mounted, last
backup recent — would be an independent signal. Not built as of 2026-09-15.

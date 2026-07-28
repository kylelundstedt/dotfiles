# VM disk weight — deployment lane + overlay pruning

> Measured and decided 2026-07-27, prompted by [`ryanlewis/exeslim`](https://github.com/ryanlewis/exeslim),
> a minimal exe.dev base image. Two questions came out of it: should
> deployment-only VMs stop using `boldsoftware/exeuntu`, and is our own
> `~/.local` overlay carrying too much weight everywhere else?
>
> Answers: **yes to a forked slim image for the deployment lane** (starting with
> `rss-feed`), **yes to pruning** (~20% of measured fleet disk is recoverable
> garbage), and **yes in principle to a slim base for dev VMs too** — but _not_
> to baking our toolchain into a custom image, which relocates bytes rather
> than removing them and costs `upgrade-vm`'s in-place path. Those last two are
> separate axes; see Decision 3.

## Why disk is worth attention at all

exe.dev meters **disk usage and outbound bandwidth**; CPU and RAM are not
billed. On individual plans the disk allowance is **pooled across all your
VMs**, and overage is charged on average GiB-months, not peak
(<https://exe.dev/docs/billing/usage.md>). Usage is the ext4 filesystem usage of
each VM, not its allocated capacity
(<https://exe.dev/docs/faq/disk-usage.md>).

Two consequences that shape every decision below:

1. Per-VM bloat is a **shared** cost, so it compounds with fleet size.
2. You are billed for bytes **in your filesystem**. Moving a tool from
   `~/.local` into a custom image relocates the bytes; it does not remove them.
   An image only helps by _deleting_ content — which is exactly what exeslim
   does, and why a slim base pays off on any lane while _baking_ our own tools
   into an image pays off on none.

## Measured state — 2026-07-27

Seven VMs plus `klundstedt-mini`, measured over the tailnet with a read-only
script. `iv-foundry-stage2` and `iv-entire-agent-shelley` (both created
2026-07-26) were **not measured** — they are not tailnet-joined, which is the
expected default under the no-hook contract ([exe-dev.md](exe-dev.md)).

| Host                  |  used | claude |  node | caches |   zed | quarto | **reclaim** | after |
| --------------------- | ----: | -----: | ----: | -----: | ----: | -----: | ----------: | ----: |
| `iv-home`             | 15.2G |   492M |     — |   201M |  327M |      — |   **1.00G** | 14.2G |
| `iv-gitlake-examples` | 13.0G |   502M |  202M |   650M |  120M |      — |   **1.44G** | 11.6G |
| `iv-docs`             | 11.8G |   760M |  202M |  1585M |  161M |      — |   **2.64G** |  9.2G |
| `klundstedt-mini`     | 11.7G |   720M |     — |  6361M |     — |      — |   **6.92G** |  4.8G |
| `kgl-thoughts`        |  9.7G |   993M |     — |  1058M |  156M |      — |   **2.16G** |  7.5G |
| `rss-feed`            |  7.8G |      — |  202M |   445M |  318M |   423M |   **1.35G** |  6.4G |
| `iv-ave-adapters`     |  7.4G |   445M |  202M |   344M |  117M |      — |   **1.08G** |  6.3G |
| `iv-gitlake`          |  7.1G |      — |  202M |   358M |     — |      — |   **0.55G** |  6.5G |
| **TOTAL**             | 83.7G |  3911M | 1010M | 11001M | 1198M |   423M |  **17.13G** | 66.6G |

**20% of measured fleet disk is recoverable without removing a single tool
anyone uses.**

### What each column is, and why it is safe

- **claude** — `~/.local/share/claude/versions/` holds flat per-version
  binaries at ~250 MB each and is never pruned by the installer.
  `~/.local/bin/claude` symlinks the one in use; everything else is dead.
  `kgl-thoughts` retains 5, `iv-docs` 4, the mini 4.
- **node** — stale fnm versions. `aliases/default` resolves to
  `node-versions/<v>/installation`, so the in-use version is identifiable;
  only the others are counted.
- **caches** — `~/.cache/uv`, `~/.cache/go-build`, `~/.npm`. Pure regenerable
  cache. The mini dominates at **5488M uv + 874M npm**.
- **zed** — `~/.zed_server` + `~/.local/share/zed`, re-fetched on the next
  remote connection.
- **quarto** — counted only where no real Quarto site exists. Only `rss-feed`
  qualifies: its sole `_quarto.yml` files belong to the vendored `dotfiles`
  and `iv-image` clones, not to anything it serves.

Working set (**not** counted as reclaimable): `~/.local/bin` at 640–970 MB per
VM — `codex` 285M, `tigris` 93M, `carapace` 78M, `uv` 63M, `duckdb` 60M, `op`
40M, `gh` 39M. These are legitimately-sized static binaries and the honest
price of the toolchain.

### Measurement caveats

The first pass was wrong in two ways worth recording, because both would have
produced a destructive prune rule:

- On `rss-feed` and `iv-gitlake` the Claude symlink did not resolve into
  `versions/`, so the **only installed version** was scored as reclaimable. The
  rule now falls back to newest-by-mtime and never proposes removing a lone
  version.
- The fnm default alias resolves to `.../installation`, not to a version
  directory, so **every** node version scored as stale. The rule now walks up
  one level and claims nothing when the default cannot be resolved.

Any prune implementation must keep both guards.

## Decision 1 — fork exeslim for a deployment lane, start with `rss-feed`

`rss-feed` is the clean case. Verified on the box:

- `srv.service` runs `/home/exedev/rss-feed/rss-feed` — one static 10 MB Go
  binary. `srv.service`, `rss-feed-healthcheck.{service,timer}`, and
  `healthcheck.sh` are all committed in the repo.
- No database, no state files.
- Tags are `["llm"]` — **no `iv` tag**, so it is already outside the
  `provision-iv.sh` baseline.
- AgentsView recorded **0 agent sessions**: nobody works there interactively.
- It is one of only two VMs with `public_proxy: true`, so dropping compilers,
  git, Python, and Node is a real attack-surface reduction.
- Yet it currently carries 423M of unused Quarto, 318M of Zed server, stale
  node, and a stray `~/iv-image` clone — all pure lane leakage.

**Fork rather than consume.** `ghcr.io/ryanlewis/exeslim` is a personal
account, not boldsoftware, rebuilt weekly by an Action we do not control, and
the VMs in question are the internet-facing ones. The Dockerfile is ~180 lines
of systemd masking and exe.dev wiring — cheap to vendor under `kylelundstedt`,
and consistent with this repo's "GitHub is the canonical source of truth"
boundary. Pin by immutable build ID (`<date>.<run>.<attempt>`) either way: the
upstream README is explicit that exe.dev caches mutable tags and can serve a
stale `:latest`.

Build the Go binary on the mini (`GOOS=linux GOARCH=amd64`) and ship the
artifact. Building on the production box was never a good idea; exeslim just
removes the option.

## Decision 2 — prune, and make it recurring

This is the highest-ROI move and needs no architectural change. It must be a
**timer, not a one-off**: the Claude versions directory regrows on every
update, which is precisely how it reached 1.3G on `kgl-thoughts`.

Shape it like the existing per-VM healthcheck timers, and decide it together
with the still-open AgentsView **retention mechanism** in
[`TODO.md`](../TODO.md) — same problem (unbounded local growth, no mechanism),
and it would be silly to invent two different answers.

Note the mini is the single biggest target (6.92G, nearly all uv cache) and is
also the Tigris backup source — pruning there shrinks the nightly backup too
([tigris-backup-runbook.md](tigris-backup-runbook.md)).

## Decision 3 — two separate axes, and only one of them is a "no"

> **Corrected 2026-07-28.** The first version of this section rejected "a
> slimmer dev image" outright. That conflated two independent choices and was
> wrong on the more interesting one. Both are recorded here because the
> conflation is easy to repeat.

**Axis 1 — the base image.** `exeuntu` vs something slim. This is worth real
money on _both_ lanes, and measurement on `iv-docs` says so:

| In exeuntu's `/usr`                        |  size | do dev boxes need it?                                 |
| ------------------------------------------ | ----: | ----------------------------------------------------- |
| `/usr/local/aws-cli`                       |  533M | yes — but see note below, this is **not** a duplicate |
| `/usr/bin/{docker,dockerd,containerd,ctr}` | ~180M | unused on our VMs                                     |
| `/usr/local/go`                            |  269M | only where a Go service is built                      |
| `/usr/bin/archil`                          |  207M | only on archil hosts                                  |
| `/usr/lib/snapd` + `/usr/bin/snap`         |  125M | unused                                                |
| `/usr/bin/gh`                              |   44M | **duplicate** — we install 39M into `~/.local/bin`    |
| `/usr/bin/tailscale`                       |   31M | yes                                                   |
| gcc / lto-dump                             |  ~53M | rarely                                                |

On `aws-cli`, the obvious inference is wrong and was corrected after checking:
`provision-iv.sh` installs to `/usr/local/bin/aws`, the **same path** the image
uses, so it replaces the image's copy rather than adding a second one. One
533M copy, and it is in use. Only `gh` is genuinely duplicated — our 39M in
`~/.local/bin` shadows the image's 44M — which is a 39M nuisance, not a lever.

The lever is the ~900M of docker, snapd, and compilers that nothing on this
fleet touches, plus `go` and `archil` on the hosts that don't need them. **A
slim base for dev VMs is a real saving and worth pursuing** — call it 2–3G per
box once the apt packages a dev box genuinely needs are added back, on top of
what pruning recovers.

**Axis 2 — how our tools arrive.** A re-runnable script (`provision-iv.sh`,
`install.sh`) vs baked into a custom image. **This is the "no."**

1. **Baking saves zero billed bytes.** Billing is on your VM's filesystem
   usage. Moving `duckdb` and `codex` from `~/.local` into `/usr` relocates
   bytes between directories; there is no cross-VM dedup to harvest.
2. **Baking trades away in-place upgradability.** The base image is fixed at VM
   create. `upgrade-vm` works today precisely because the software layer is a
   re-runnable script — no recreate, no disk wipe. Bake tools in and a DuckDB
   point bump becomes destroy/recreate on boxes holding Shelley databases,
   repos, and agent session history.
3. **`provision-iv.sh` already is the image.** Every tool version-pinned and
   checksum-verified, arch-aware, idempotent. Baking would add faster VM
   creation and nothing else.

The two axes are independent, and that is the whole point: **slim base +
existing provisioning script on top** captures the disk win on dev VMs _while
keeping `upgrade-vm` exactly as it is._ Nothing has to be baked.

**What blocks it today** is not desirability but bootstrap: `provision-iv.sh`
is written for "a stock exeuntu VM," and the documented flow starts with a
`git clone` on the VM — exeslim has no git, Python, or Node. Making the dev
lane slim means making the provisioning script self-bootstrapping from a bare
base (`install.sh` already does this for `curl | bash`). That is a real piece
of work, and it should follow the deployment lane rather than lead it, so the
bootstrap is proven on a box with nothing at stake.

**Revisit trigger for _baking_:** VM creation time becoming the pain. Disk is
not it.

Related but separate: `install.sh` and `provision-iv.sh` have exactly one
profile and it is "full dev." That is why `rss-feed` carries Quarto. A
minimal/deploy profile is the fix, and it is what makes the slim lane coherent:

| Lane         | Base                   | Provisioning   | Upgrade path           |
| ------------ | ---------------------- | -------------- | ---------------------- |
| Dev (today)  | `exeuntu`              | full profile   | `upgrade-vm`, in place |
| Dev (target) | forked exeslim, pinned | full profile   | `upgrade-vm`, in place |
| Deployment   | forked exeslim, pinned | deploy profile | destroy + recreate     |

## Plan

**A. Prune** — script done, fan-out pending

1. ~~Write the prune script with both guards~~ — `maint/.local/bin/prune-disk`,
   dry-run by default, stowed fleet-wide into `~/.local/bin`.
2. ~~Dry-run fleet-wide~~ — all seven joined VMs + the mini reconcile against
   the table above.
3. ~~Execute on one VM and verify~~ — applied on `rss-feed` 2026-07-28:
   7.8G → 6.8G, `srv.service` and the healthcheck timer still active, app
   returns 200, `claude`/`node`/`uv` all still work. Actual 1.06G vs a 1.35G
   estimate, because `uv cache prune` keeps live entries.
4. Fan out to the remaining VMs and the mini (**~15G outstanding**, the mini
   alone 6.9G).
5. Decide the recurring mechanism alongside AgentsView retention; install as a
   timer.

### Outcome — 2026-07-28

**Prune, fleet-wide: ~10.1G actual reclaimed** (vs a 17.13G upper bound; the
gap is `uv cache prune` keeping live entries, which the estimate could not
model). Per host: mini 3.10G, `iv-docs` 1.64G, `kgl-thoughts` 1.64G,
`rss-feed` 1.06G, `iv-gitlake-examples` 859M, `iv-home` 828M,
`iv-ave-adapters` 799M, `iv-gitlake` 241M. No breakage on any host.

**`rss-feed` cutover: 7.8G → 268M.** Rebuilt on
`ghcr.io/kylelundstedt/exeslim:2026-07-28.1.1`. Feed output is byte-identical
to the pre-cutover baseline (motherduck 18 items, archil 19, both HTTP 200,
titles identical). `git`, `python3`, `go`, `node`, `docker`, `nginx`, `uv`, and
`claude` are all absent from the box.

**B. `rss-feed` → forked exeslim** — done

1. ~~Fork under `kylelundstedt`; own the weekly rebuild~~ —
   [`kylelundstedt/exeslim`](https://github.com/kylelundstedt/exeslim).
   Divergence is one owner-relative line in `build.yml` plus `FORK.md`, so
   upstream merges cleanly. First build published and verified anonymously
   pullable: **`ghcr.io/kylelundstedt/exeslim:2026-07-28.1.1`** (14 layers,
   56 MB compressed).
2. ~~Cross-compile and ship as an artifact~~ — `deploy.sh` in the service repo
   does the whole rebuild (cross-compile, ship, enable, verify) in one SSH
   connection, and is what makes a destroy/recreate lane survivable. Tested
   end-to-end against the live VM.
3. ~~Update the monitoring registry~~ — collector `[[remote_hosts]]` block
   removed, host added to `agentsview-coverage-exclude.txt`; both AgentsView
   checks re-verified green afterwards.
4. ~~Create from the pinned build ID, verify, delete the old VM~~ — done.
5. ~~Record in [`monitoring.md`](monitoring.md) and
   [`exe-dev-web.md`](exe-dev-web.md)~~ — done.
6. Still open: a **deploy profile** for `install.sh` (no Quarto, no Zed, no fnm,
   no agent toolchain). Not needed for `rss-feed`, which runs no dotfiles
   overlay at all, but needed before a second service joins the lane.

**D. Slim base for dev VMs — the actual recommendation**

**Adopt it for new VMs only. Never migrate an existing dev box for this.**

The saving is ~2–3G per box. Applying it to an existing dev VM costs a
destroy/recreate of a machine holding repos, a Shelley database, and agent
session history — `iv-home` is 15G and `iv-gitlake-examples` 13G, and after
pruning almost all of that is real work product, not waste. Paying a migration
of _that_ to recover 3G is a bad trade, and doing it six times is a worse one.

New VMs are a different story: they cost nothing to build slim, and the fleet
turns over on its own.

So:

1. **Next time a dev VM is created from scratch, build it on the forked
   exeslim** and make that the pilot. The one real unknown is bootstrap —
   `provision-iv.sh` assumes stock exeuntu and its documented flow opens with a
   `git clone`, which a bare base cannot do. Either pre-install `git` via apt
   in the setup script, or teach the script to self-bootstrap the way
   `install.sh` already does for `curl | bash`.
2. **If that pilot is clean, make slim the default base for new dev VMs** and
   let existing ones age out naturally.
3. **If it is not clean, stop.** The dev lane's value is `upgrade-vm`'s
   in-place path; do not trade that for 3G.

Independently and cheaply: drop the redundant `gh` from the personal overlay on
IV VMs (39M/box, no image change, no migration).

**C. `kgl-thoughts` — not now**

It is the fleet's busiest agent host (111 Claude sessions, 49M Shelley DB, the
reason it sits at a 15m AgentsView interval —
[agentsview-pilot.md](agentsview-pilot.md)) and it carries `lundstedt.us` /
`www.lundstedt.us`. It is a dev box that happens to serve nginx. It becomes a
candidate only after authoring moves to the mini and the VM merely serves built
output. Revisit after B proves the lane.

## Gotchas

- **`agentsview-coverage` is fail-closed and hourly.** Recreating `rss-feed`
  without the AgentsView source daemon will fire it. Zero sessions means
  nothing is lost by dropping the source — but the registry edit must land
  _before_ cutover, not after.
- **Never prune a lone Claude version**, and never trust the symlink to resolve
  into `versions/`. See "Measurement caveats".
- **Several VMs are pinned to an old Claude.** `iv-ave-adapters`, `iv-gitlake`,
  `kgl-thoughts`, and `rss-feed` all symlink `2.1.212` while newer binaries sit
  unlinked beside them; `iv-docs` is on `2.1.219`, the mini on `2.1.220`. Worth
  understanding _why_ before pruning, since the unlinked newer versions are
  what a naive rule would delete.
- **Base image is fixed at create.** Any image change is destroy/recreate, so a
  deployment-lane service must be fully reproducible from repo + setup script.
  `rss-feed` already is; verify that property before adding a second service to
  the lane.

Learned during the cutover, both of which cost time:

- **A recreated VM presents a new SSH host key, and `.exe.xyz` is not covered
  by the tailnet's `StrictHostKeyChecking no`.** Every routine `ssh <vm>` in
  this fleet goes over the tailnet, where the `Match host *.ts.net` block skips
  host keys — so the first `.exe.xyz` connection to a rebuilt VM fails under
  `BatchMode`. `ssh-keyscan` does not help: exe.dev's sshd offers `ssh-rsa`,
  which keyscan does not request by default. Use
  `StrictHostKeyChecking=accept-new`, as `deploy.sh` does. A slim deployment
  VM has no tailscale, so `.exe.xyz` is the only way in.
- **The proxy comes back private.** `share set-public <vm>` is a required step
  after recreating a public service; a new VM does not inherit the old one's
  sharing. Forgetting it is a silent outage behind a login redirect.
- **Budget for the SYN-drop backoff.** Failed connections during the rebuild
  count against the per-source-IP rate, so a fumbled first attempt makes the
  next few worse. The successful run needed a ~150s pause. Plan the cutover as
  one scripted pass rather than interactive poking.

## Open questions

- Is Claude Code's version retention configurable, or must pruning be external?
- Does the deploy profile belong in `install.sh` as a flag, or as a separate
  thin script? A `--profile=deploy` flag keeps one entry point; a separate
  script keeps the slim lane free of the full script's assumptions.
- The two unmeasured VMs (`iv-foundry-stage2`, `iv-entire-agent-shelley`) need
  a pass once joined, to confirm the 20% figure holds fleet-wide.

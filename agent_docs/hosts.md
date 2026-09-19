# Hosts

Where this repo runs, and what each host is responsible for. Two stable macOS
machines with distinct roles, plus the ephemeral Linux VM fleet. The tailnet is
`dojo-sun.ts.net`.

## macOS

Both Macs stow the same dotfiles via `install.sh` — the macOS path is identical,
and host-specific behavior is gated at runtime on `scutil --get LocalHostName`.
The differences below are the load-bearing ones a runbook or an agent needs to
know before acting.

### `klundstedt-mini` — always-on Mac mini

The operational host and author/merge host for both dotfiles and iv-image.
Everything scheduled, backed up, served, or coordinated across the exe.dev
fleet runs here.

- **Tailscale:** open-source `tailscaled` (brew formula, system daemon via
  `sudo brew services`), not the standard app. Needs `--tailscale-ssh` on the
  **first** `install.sh` run; self-maintains after. It's a **tagged** device
  (`tag:mini`, persistent) — its rebuild path mints a non-ephemeral key via
  `op`. It left `tag:dev` on 2026-09-02 (AgentsView collector move, see
  [agentsview-pilot.md](agentsview-pilot.md)). A tagged node is not
  `autogroup:member`, so `tag:mini` must be named as a _source_ in the dev-mesh
  and prod-SSH rules or the mini loses all outbound tailnet reach — which is
  exactly what happened until 2026-09-10.
  Formula upgrades are a manual ritual (see `AGENTS.md` → Tailscale).
- **SSH target:** reachable at `klundstedt-mini.dojo-sun.ts.net` via **Tailscale
  SSH** (`RunSSH: true`), which authenticates on tailnet ACLs and never reads
  `authorized_keys`. Also runs a dedicated mosh-bootstrap sshd on port `2222`
  (`ssh/sshd-moshi/`, for the herdr pilot), bound to the Tailscale address and
  keyed off `~/.ssh/authorized_keys_moshi` — the break-glass path if Tailscale
  SSH is unavailable. Native Remote Login (`com.openssh.sshd`, `*:22`) and
  Screen Sharing (`*:5900`) are **both off** as of 2026-07-31 — each was
  reachable on the LAN; Remote Login's only credentials were three stale
  JumpCloud keys, now deleted, and Screen Sharing had gone 14 days unused.
  These are independent daemons: turning those two off left Tailscale SSH and
  `2222` untouched. Note it also leaves **no remote GUI path** to the mini,
  which matters when 1Password needs unlocking here. See
  [ssh-keys.md](ssh-keys.md).
- **Backup:** `backup/tigris-backup.sh` runs here **only** (guarded by a
  `LocalHostName` check in `backup/_lib.sh`). `~/` + Photos → the IA
  `klundstedt-mini-backup` bucket; the external `OWC8TB` volumes → the
  GLACIER_IR `klundstedt-mini-archive` bucket. Full procedure:
  [tigris-backup-runbook.md](tigris-backup-runbook.md).
- **`hub-mcp` server:** the personal `hub-mcp` server runs here (code in the
  private `kylelundstedt/personal-mcp` repo, cloned to
  `~/github/kylelundstedt/personal-mcp`; its `bootstrap.sh` loads the server +
  ingest LaunchAgents). Binds `127.0.0.1:8765`, exposed tailnet-only via
  `tailscale serve` at `https://klundstedt-mini.dojo-sun.ts.net/mcp`.
- **LM Studio API:** the LM Studio server binds `127.0.0.1:1234` (loopback
  only; the app's "serve on local network" toggle stays off). One tailnet-only
  door: `https://klundstedt-mini.dojo-sun.ts.net/lmstudio/v1`, a path mount on
  the `:443` serve listener (serve strips the prefix; the `:8443` door added
  earlier on 2026-09-15 was retired the same day as redundant). Fleet VMs reach
  it through the `iv-llm-relay` VM and exe.dev's `lmstudio` llm integration —
  [llm-relay.md](llm-relay.md); watched by `lmstudio-door`
  ([monitoring.md](monitoring.md)). No app-layer auth; tailnet policy
  (`tag:relay` → `tcp:443`) is the gate.
  Serve config lives in tailscaled state, not in this repo — `tailscale serve
status` is the source of truth. Remove with `tailscale serve --https=8443
off` / `tailscale serve --https=443 --set-path=/lmstudio off`.
- **`~/archives/`:** msgvault email, calendar DuckDB, the search hub, and
  external-volume archives. The data contract between dotfiles (backup) and
  personal-mcp (serve).
- **AgentsView:** since 2026-09-02 the mini is a plain **source** (launchd
  daemon on its tailnet address `:8080`, pulled by the collector); the fleet
  archive lives on the `iv-agentsview` VM. Two staged backup copies under
  `~/archives/agentsview/`: the mini's own database (`agentsview-snapshot.sh`)
  and, since 2026-09-15, the collector's fleet archive plus its config
  (`collector/`, `agentsview-collector-snapshot.sh`), both pulled into the
  nightly Tigris run — [tigris-backup-runbook.md](tigris-backup-runbook.md),
  [agentsview-peer-path.md](agentsview-peer-path.md).
- **Monitoring:** the healthchecks.io registry ([monitoring.md](monitoring.md))
  covers this host's scheduled jobs.
- **External disk:** `OWC8TB` (encrypted; unlocked by `backup/owc8tb-unlock.sh`).
- **Git ownership:** authors and merges `kylelundstedt/dotfiles` from
  `~/dotfiles` and `kylelundstedt/iv-image` from
  `~/github/kylelundstedt/iv-image`; performs GitHub HTTPS authentication and
  coordinates fleet rollout. See
  [git-https-migration.md](git-https-migration.md).

### `klundstedt-mbp` — dev laptop

The interactive development machine. Runs the full macOS `install.sh` path but
hosts none of the mini's operational duties.

- **Tailscale:** the standard Tailscale app — no `--tailscale-ssh` flag. A
  **user** device (browser join), not tagged.
- **No scheduled jobs:** the backup/sync LaunchAgents are mini-gated and no-op
  here.
- **`hub-mcp` client, not server:** `install.sh` registers the MCP _client_
  pointed at the mini's tailnet URL; the server itself never runs here.
- **herdr client-only (pilot):** runs no herdr server — you attach via Ghostty
  tabs to the servers on the mini + VMs, so the agent sessions (dotfiles,
  personal-mcp) live on the always-on mini and survive the laptop sleeping. See
  [herdr-pilot.md](herdr-pilot.md).
- **Verification split:** interactive editing and one-off dev happen here;
  anything that needs the live `~/archives` or LM Studio is verified on the mini
  over the tailnet.

### Shared

Both personal Macs register the personal-only MCP servers (`github-home`,
`tigris`, `readwise`) and the `hub-mcp` client (mini → `localhost`, mbp →
tailnet URL).

## Linux — exe.dev VMs

Most of the Linux side is an ephemeral, tag-scoped VM fleet. There is no
persistent dotfiles authoring or canary VM: `kgl-dotfiles` was retired on
2026-07-22 after its AgentsView work was mirrored to `klundstedt-mini` and its
Shelley database and repository bundles were archived under
`~/archives/vm-retirements/` on the mini.

Create Linux compatibility canaries on demand (normally through
`./test-install.sh exe`) and delete them after validation. Attach a writer
integration only for an explicit temporary push test and detach it immediately
afterward. `klundstedt-mini` authors and merges dotfiles and iv-image; ordinary
project VMs consume both read-only. Account control-plane changes
(integrations, attachments, and VM lifecycle) are made from
`klundstedt-mini` or another Mac with the account SSH credential.

Lifecycle (create, join tailnet, upgrade) lives in the `exe-dev` /
`join-tailnet` / `upgrade-vm` skills, not here.

Two VMs are bare **relays**, not dev boxes (exeslim + nginx, no agent harness,
no secrets beyond a header key): `iv-personal-mcp-relay` bridges hub-mcp on the
mini to exe.dev over a private peer proxy; `iv-llm-relay` bridges LM Studio on
the mini (and later the Studio Ultra) to the `lmstudio` llm integration over a
public, header-gated port — [llm-relay.md](llm-relay.md).

### Platform notes

- Primary Linux target is exe.dev VMs running `boldsoftware/exeuntu` (Ubuntu
  24.04 + kitchen-sink tools).
- Apple Containers and Sprites are alternative platforms, not actively
  maintained (see `TODO.md`).
- `install.sh` skips tools already present on the image (`need` checks) to
  avoid redundant downloads. On IV VMs, including Apple Container guests with
  `~/iv-provision.lock`, it runs as a thin personal overlay on top of
  iv-image's `provision-iv.sh` (see [repo-boundaries.md](repo-boundaries.md)).
- **Provisioning floor: `iv-provision` >= 3.0.27, else AgentsView collection
  breaks** (recorded 2026-09-19). Every reachable fleet host is checked out at
  **3.0.26**, which pins `AGENTSVIEW_VERSION=0.38.1`, while all of them _run_
  **0.43.0** — installed out-of-band during the collector rebuild. `3.0.25` pins
  0.38.1 as well; only **3.0.27** pins 0.43.0. Running `provision-iv.sh` at a
  host's own checked-out tag therefore **downgrades** AgentsView, and the rebuilt
  collector refuses a 0.38.1 source.

  This is latent rather than live: nothing is broken until somebody
  re-provisions — which is the routine repair action (`upgrade-vm` Path A, ~23
  seconds), so the trap is armed on the most ordinary operation there is. When
  reasoning about fleet version state, "on 3.0.2x" is not the useful predicate;
  **>= 3.0.27** is. And a host's checkout tag is not evidence of what it is
  running: on 2026-09-19 the two disagreed on all 17 reachable hosts. Check both.

- **`iv-provision` is the control-plane host, and its name now undersells it**
  (noted 2026-09-15). It creates VMs, lists them, and manages integrations — and
  since 2026-09-15 it also runs the scheduled `entire-push-check`
  (`provisioning/iv-provision/`), because the exe.dev inventory reaches it through
  the http-proxy integration with no SSH key. The defining property of this host
  is **control-plane access**, not provisioning specifically; reading the
  inventory for a monitoring check is the same capability, so this is not scope
  creep so much as a name that describes one use of the capability rather than
  the capability.

  The gap is real but it is a labelling gap: the VM is `iv-provision`, its emoji
  is ⚙️, and `https://iv-provision.exe.xyz` serves nothing but the exe.dev auth
  redirect, so nothing about the host announces the monitoring role. A rename
  (`iv-control`?) was considered and **not** done: renames here are hazardous by
  this repo's own record — deleting or renaming a VM does not free its tailnet
  node, `tailscale set --hostname` does not rename a registered one, and a
  2026-07-30 rename left `iv-foundry-stage2` off the tailnet when 1Password
  locked mid-operation. It would also touch integrations, the collector config,
  `checks.manifest`, `deploy.sh` defaults and every doc reference, while the
  repo `iv-provision` keeps its name regardless. Cost exceeds the benefit of a
  clearer noun. Recording the roles here is the cheap fix; a short landing page
  on the VM's https URL would be the next-cheapest if the ambiguity keeps
  costing anything.

- **AgentsView canaries:** `iv-docs` (exe.dev) runs the pinned, tailnet-only
  authenticated source service. (`iv-sandbox`, the original second canary, was
  decommissioned 2026-07-22 with the LLM gateway — see
  [CHANGELOG.md](../CHANGELOG.md).) Binary installation is unconditional in
  `iv-image`; service activation requires a joined tailnet and a mode-`0600`
  per-host token file.
- Shell change targets zsh; in non-interactive mode it may be skipped without
  sudo/root.

### Testing on Linux

Use the included test script, which tests across Apple Container, Sprite, and
exe.dev:

```bash
./test-install.sh
```

For a quick one-off Docker test:

```bash
docker run --rm -it ghcr.io/astral-sh/uv:python3.12-bookworm bash -c \
  "apt-get update && apt-get install -y sudo zsh && \
   curl -fsSL https://raw.githubusercontent.com/kylelundstedt/dotfiles/master/install.sh | bash; exec zsh -l"
```

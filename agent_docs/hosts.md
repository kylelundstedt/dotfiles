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

The operational host. Everything scheduled, backed up, or served runs here.

- **Tailscale:** open-source `tailscaled` (brew formula, system daemon via
  `sudo brew services`), not the standard app. Needs `--tailscale-ssh` on the
  **first** `install.sh` run; self-maintains after. It's a **tagged** device
  (`tag:dev`, persistent) — its rebuild path mints a non-ephemeral key via `op`.
  Formula upgrades are a manual ritual (see `AGENTS.md` → Tailscale).
- **SSH target:** reachable at `klundstedt-mini.dojo-sun.ts.net`. Also runs a
  dedicated mosh-bootstrap sshd on port `2222` (`ssh/sshd-moshi/`, for the
  herdr pilot).
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
- **`~/archives/`:** msgvault email, calendar DuckDB, the search hub, and
  external-volume archives. The data contract between dotfiles (backup) and
  personal-mcp (serve).
- **Monitoring:** the healthchecks.io registry ([monitoring.md](monitoring.md))
  covers this host's scheduled jobs.
- **External disk:** `OWC8TB` (encrypted; unlocked by `backup/owc8tb-unlock.sh`).

### `klundstedt-mbp` — dev laptop

The interactive development machine. Runs the full macOS `install.sh` path but
hosts none of the mini's operational duties.

- **Tailscale:** the standard Tailscale app — no `--tailscale-ssh` flag. A
  **user** device (browser join), not tagged.
- **No scheduled jobs:** the backup/sync LaunchAgents are mini-gated and no-op
  here.
- **`hub-mcp` client, not server:** `install.sh` registers the MCP *client*
  pointed at the mini's tailnet URL; the server itself never runs here.
- **Verification split:** dotfiles-side edits happen here; anything that needs
  the live `~/archives` or LM Studio must be verified on the mini over the
  tailnet.

### Shared

Both personal Macs register the personal-only MCP servers (`github-home`,
`tigris`, `readwise`) and the `hub-mcp` client (mini → `localhost`, mbp →
tailnet URL).

## Linux — exe.dev VMs

Unlike the Macs, the Linux side has no per-host identity: it's a fleet of
ephemeral VMs, tag-scoped rather than named. Lifecycle (create, join tailnet,
upgrade) lives in the `exe-dev` / `join-tailnet` / `upgrade-vm` skills, not
here.

### Platform notes

- Primary Linux target is exe.dev VMs running `boldsoftware/exeuntu` (Ubuntu
  24.04 + kitchen-sink tools).
- Apple Containers and Sprites are alternative platforms, not actively
  maintained (see `TODO.md`).
- `install.sh` skips tools already present on the image (`need` checks) to
  avoid redundant downloads. On IV VMs it runs as a thin personal overlay on
  top of iv-image's `provision-iv.sh` (see [repo-boundaries.md](repo-boundaries.md)).
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

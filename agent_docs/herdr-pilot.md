# herdr + Moshi pilot — one agent workflow across machines

Status: **pilot, not yet started** (planned 2026-07-14, in a personal-mcp session; this doc is
canonical). Replaces the split "Zed agent panel on Mac + exe.dev/Shelley on mobile" with
terminal-native agents multiplexed by [herdr](https://herdr.dev) and reached from iOS via
[Moshi](https://getmoshi.app). Zed stays as editor; Shelley stays for ephemeral VM work.

## Why

- Zed↔Shelley are two disjoint worlds (harness, machine, conventions, memory, session state);
  work can't move between them, only be re-explained.
- Local-process agents (Claude Code, Codex CLI) make MCP connections **from the device**, so
  tailnet-only hub-mcp works everywhere they run. Cloud-side connectors (claude.ai, mobile
  apps) can never reach it — see personal-mcp README "iPhone / iPad".
- Consolidating on one harness family retires the Shelley carve-outs (per-repo convention
  restatement exists because Shelley doesn't read `~/.claude/CLAUDE.md`).

## Topology (decided)

Two layers — **servers** (where herdr and the agents run) and **clients** (where you attach
from). The confusion to avoid: treating a remote repo-machine as an ssh target rather than a
herdr server.

### Servers — one per machine where a repo lives

- A herdr server runs on each machine hosting a repo: `klundstedt-mini` (repos: dotfiles,
  personal-mcp) and each exe.dev VM (its own repo). Agents run in panes **on that machine,
  next to their code**; clients attach to view them.
- **Do NOT collapse this into one hub session with ssh panes into the other machines** —
  herdr's agent-state sidebar is blind to agents on the far side of a raw ssh pane. Reach a
  remote with `herdr --remote <host>`, which attaches to *that host's herdr server* (the
  sidebar sees its agents); an ssh pane does not, and is the anti-pattern.
- `klundstedt-mini` is the **always-on** server (monitored; hub-mcp at localhost; the only
  machine that can ever send iMessage / run LM Studio). Its repos live in named per-project
  sessions: `--session dotfiles`, `--session personal-mcp`. It is also the phone's landing
  host (below). That — always-on server + phone landing — is all "primary" means; it is
  **not** a hub that other machines' agents route through.

### Clients — where you attach from

- **Desk = `klundstedt-mbp`, client only** (no herdr server runs here). One Ghostty tab per
  project, each attaching to the server where that repo lives:
  `herdr --remote klundstedt-mini --session dotfiles`, `herdr --remote <vm>` for an IV repo.
  Because the agents live on the always-on servers, work survives the laptop sleeping. Local
  keybindings apply on remote attach. Use **Ghostty** (already stow-managed here), not Zed's
  embedded terminal — herdr inside Zed re-couples agents to the editor, the coupling this
  pilot removes. Zed stays editor-only.
- **Phone = Moshi, ONE profile.** mosh to the mini (its single always-on landing host), then
  jump onward with `herdr --remote <vm>` or attach to a mini-local session.
  `herdr agent attach <name>` is the right grain for a phone screen.
- **Phone — web alternative: [collie](https://github.com/AltanS/collie)** (community plugin).
  A tailnet-only PWA (Bun bridge + `systemd --user`, `tailscale serve` on :8787) that surfaces
  a host's herdr agents in a phone browser with push notifications — the "web UI to *local*
  agents" that Shelley's cloud UI structurally can't be (Shelley can't reach tailnet-only
  `hub-mcp`). Same slot as the ttyd browser-view under Boundaries, purpose-built. **Trust:**
  it is "remote shell access to your machine by design" — `tailscale serve` only (never
  `funnel`); set `COLLIE_TRUSTED_USER` + `COLLIE_PUBLIC_HOSTS` immediately after start.
- **Review sidebar: [herdr-reviewr](https://github.com/persiyanov/herdr-reviewr)** (community
  plugin) — comment on an agent's diff and send it back; read-only PR/checks view. Both are
  `herdr-plugin`-topic plugins with **no review queue** — vet before trusting.

### Reaching VMs

- Tailnet name only (after `/join-tailnet`), never `*.exe.xyz` (SYN-drop lockout rules).
- herdr is provisioned by default (decided 2026-07-17, ahead of the original post-pilot gate):
  pinned in iv-image `provision-iv.sh` for VMs, floating in dotfiles `install.sh` for Macs
  (`team` row in `provisioning/tools.manifest`). VMs not yet reprovisioned still get the
  binary via `herdr --remote <vm>` self-bootstrap.

## Boundaries (decided in the same discussion)

- hub-mcp stays **read-only forever**. Future send-email/text/calendar actions go in a
  separate act-mcp server, **draft-first** with an audit log (archive content is untrusted
  input — prompt-injection + actuators must not share a toolset). act-mcp lives on the mini
  (Messages.app) and registers on strictly fewer machines than hub-mcp.
- `install.sh`'s macOS gate on hub-mcp registration doubles as the personal/work boundary —
  do not register hub-mcp on IV VMs without an explicit decision.
- Local LLM (LM Studio) = background archive enrichment, not the acting agent.
- No Shelley→mini bridge (Shelley reporting on herdr sessions over ssh would give an
  exe.dev-served web UI standing access to the mini). If a browser view is wanted later:
  ttyd behind `tailscale serve`, tailnet-only.

## Pilot checklist

- [x] mini: `brew install mosh`; install herdr (mini + mbp) — mosh added to the Brewfile,
      herdr to the dotfiles tools layer (`install.sh` + `provisioning/tools.manifest`, NOT
      the Brewfile) 2026-07-17; installed on the mini (mbp gets herdr on any `install.sh`
      run, mosh on an `install.sh --apps` run)
- [ ] Moshi on iPhone/iPad: one profile → klundstedt-mini over Tailscale.
      **Gotcha found 2026-07-17: Tailscale SSH cannot bootstrap mosh** (tailscaled grabs
      port 22; its exec sessions never launch mosh-server — reproduced from iv-docs, and
      documented at getmoshi.app/guides/tailscale). Keeping Tailscale SSH on 22 (the
      identity-based-SSH design stands); mosh instead bootstraps via a second sshd on
      **port 2222**, tailnet-IP-bound, pubkey-only, trusting only
      `~/.ssh/authorized_keys_moshi` — files + installer in `ssh/sshd-moshi/`
      (`sudo install-sshd-moshi.sh`, mini-only, re-runnable). Moshi profile: host
      `klundstedt-mini.dojo-sun.ts.net`, port `2222`, user `klundstedt`, key generated
      on-device in Moshi (private key never leaves the phone; pubkey appended to
      `authorized_keys_moshi`, dated comment, one line per device = per-device revocation),
      mosh-server path `/opt/homebrew/bin/mosh-server`. Same-day hardening: the three stale
      `authorized_keys` entries (2022-era + kyle-imac; private halves in no current store)
      replaced with the 1P `iv-klundstedt-2024-01` pubkey as the Macs' key-auth fallback.
- [ ] Verify on a throwaway session: detach/reattach, VM suspend/resume survival, `--takeover`
      semantics when Mac + phone attach to the same session
- [ ] Run one real project per machine for a week (dotfiles on mini, one IV repo on its VM)
- [ ] Success test: the Zed↔Shelley context-switch discomfort disappears; work started at the
      desk continues from the phone
- [x] Then decide: herdr into iv-image tool layer (zero-prompt provisioning) or keep
      self-bootstrap — decided early (2026-07-17, before the week of use): pinned into
      `provision-iv.sh` with locally computed SHA-256s (upstream ships no checksums)
- [ ] Retire Shelley-specific conventions where they no longer pay (still gated on the
      pilot passing)

## Non-goals

herdr is ~weeks old (AGPL/commercial dual-license) — keep tmux muscle memory as fallback;
don't burn boats until the pilot passes.

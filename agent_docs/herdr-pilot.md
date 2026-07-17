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

- **One herdr server per machine where a repo lives**; agents run in panes next to their code.
  Do NOT use one hub session with ssh panes into VMs — herdr's agent-state sidebar can't see
  agents on the far side of an ssh pane.
- **klundstedt-mini = primary host** (always-on + monitored; hub-mcp at localhost; the only
  machine that can ever send iMessage / run LM Studio). Named sessions per project:
  `herdr --remote klundstedt-mini --session dotfiles` vs `--session personal-mcp`.
- **Client tabs fan out**: one terminal tab per project per `herdr --remote <host>`. Local
  keybindings apply on remote attaches. On macOS the client is **Ghostty** (already
  stow-managed here), not Zed's embedded terminal — running herdr inside Zed would re-couple
  agents to the editor, which is the coupling this pilot removes. Zed stays editor-only.
- **Phone: Moshi has ONE profile** → mosh to the mini; jump onward with `herdr --remote <vm>`
  from there. `herdr agent attach <name>` is the right grain for a phone screen.
- **Reach VMs by tailnet name only** (after `/join-tailnet`), never `*.exe.xyz` (SYN-drop
  lockout rules). herdr is provisioned by default (decided 2026-07-17, ahead of the original
  post-pilot gate): pinned in iv-image `provision-iv.sh` for VMs, floating in dotfiles
  `install.sh` for Macs (`team` row in `provisioning/tools.manifest`). VMs not yet
  reprovisioned still get the binary via `herdr --remote <vm>` self-bootstrap.

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

- [x] mini: `brew install mosh`; install herdr (mini + mbp) — added to the dotfiles tools
      layer + Brewfile 2026-07-17; installed on the mini (mbp gets both on its pending
      `install.sh --apps` run)
- [ ] Moshi on iPhone/iPad: one profile → klundstedt-mini over Tailscale. Mini side verified
      ready 2026-07-17: mosh-server at `/opt/homebrew/bin/mosh-server` (give Moshi that path —
      brew's dir may be missing from non-login PATH), firewall off, tailscaled up with
      `RunSSH=true`, target `klundstedt-mini.dojo-sun.ts.net`. Phone side blocked on
      reconnecting the iPhone's Tailscale app (offline since ~2025-11). ACL SSH rule for
      untagged-device → mini could not be verified from here (OAuth token lacks acl scope);
      first Moshi connect is the test — if denied, add an ssh rule
      `src autogroup:member → dst autogroup:self, users [klundstedt]` in the admin console.
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

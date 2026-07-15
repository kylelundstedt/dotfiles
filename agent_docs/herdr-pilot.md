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
  keybindings apply on remote attaches.
- **Phone: Moshi has ONE profile** → mosh to the mini; jump onward with `herdr --remote <vm>`
  from there. `herdr agent attach <name>` is the right grain for a phone screen.
- **Reach VMs by tailnet name only** (after `/join-tailnet`), never `*.exe.xyz` (SYN-drop
  lockout rules). First `herdr --remote <vm>` self-bootstraps the binary to `~/.local/bin` —
  no iv-image change needed for the pilot.

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

- [ ] mini: `brew install mosh`; install herdr (mini + mbp) — add to the dotfiles tools layer
- [ ] Moshi on iPhone/iPad: one profile → klundstedt-mini over Tailscale
- [ ] Verify on a throwaway session: detach/reattach, VM suspend/resume survival, `--takeover`
      semantics when Mac + phone attach to the same session
- [ ] Run one real project per machine for a week (dotfiles on mini, one IV repo on its VM)
- [ ] Success test: the Zed↔Shelley context-switch discomfort disappears; work started at the
      desk continues from the phone
- [ ] Then decide: herdr into iv-image tool layer (zero-prompt provisioning) or keep
      self-bootstrap; retire Shelley-specific conventions where they no longer pay

## Non-goals

herdr is ~weeks old (AGPL/commercial dual-license) — keep tmux muscle memory as fallback;
don't burn boats until the pilot passes.

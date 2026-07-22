# Service placement on klundstedt-mini — AC appliance VM vs. host

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

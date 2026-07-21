# LLM gateway migration plan — host stack → AC appliance VM

> Status: IN EXECUTION. Phases 1–3 complete and gates passed 2026-07-21;
> Phase 4 agent-executable items done; **paused awaiting operator
> touchpoints** (reboot tests + healthchecks.io project) — see Execution
> log. Companion to [llm-gateway.md](llm-gateway.md) (current form + target
> rationale) and [apple-container-vms.md](apple-container-vms.md) (build
> mechanics). Work the phases top to bottom — each has an acceptance gate;
> don't start the next phase until the gate passes.

## End state

- AC appliance VM **`llm-gateway`** on klundstedt-mini (exeuntu, machine mode,
  `--home-mount none`, 2 CPUs / 2 GB), its own tailnet node.
- One door for everyone: `https://llm-gateway.dojo-sun.ts.net` via the VM's own
  `tailscale serve`, access-token required. The host Caddy, the vmnet bridge
  door (`192.168.64.1:8484`), and the `klundstedt-mini:8443` serve are gone.
- Subscription tokens live only inside the VM.
- Own repo **`kylelundstedt/llm-gateway`** (personal, personal-mcp precedent)
  holding config template, systemd units, provisioning script, healthcheck,
  and runbooks.
- Own healthchecks.io check in its **own project** (repo-boundary rule,
  monitoring.md — rss-feed precedent), pinged by a systemd timer in the VM.

## Design decisions (all confirmed 2026-07-21)

1. **Drop Caddy entirely.** Host Caddy existed to (a) inject the internal
   api-key for the token-less vmnet door and (b) validate the tailnet access
   token. With one token-required door, both jobs collapse: put the gateway
   access token directly in CLIProxyAPI's `api-keys` list and
   `tailscale serve` straight to `127.0.0.1:8317`. **Verification required in
   Phase 2:** confirm Shelley's request paths (`/anthropic/*`, `/openai/*`
   prefixes vs. bare `/v1/...`) work against CLIProxyAPI without Caddy's
   routing. If a rewrite is genuinely needed, run a thin Caddy **inside** the
   VM (config in the repo) — never back on the host.
2. **iv-sandbox (and any local AC guest) switches to the tailnet URL + token**
   like every other consumer. The vmnet door dies; one auth model everywhere.
3. **Seed credentials by copying the existing token files** from
   `~/.cli-proxy-api/` on the host into the VM (they're refresh-token JSON;
   CLIProxyAPI refreshes in place). Fresh in-VM OAuth logins are the
   _contingency_, not the default — the runbook for that (tailnet SSH with
   `-L` forwarding the localhost callback port, browser on the host) goes in
   the repo, exercised only if a copied token dies.
4. **Rotate the gateway access token at cutover.** Cheap, and it cleanly
   separates old-door and new-door credentials during burn-in.
5. **Tailnet tag: `tag:dev`** — the only tag the existing OAuth client may
   mint (apple-container-vms.md). Means any tag:dev node can reach the VM at
   the network layer; the access token remains the app-layer gate, same as
   today. A dedicated `tag:appliance` needs an admin-console edit — optional
   hardening later, not a migration blocker.
6. **Version-pin CLIProxyAPI in the repo** (currently v7.2.91 / fde40c5,
   vetted 2026-07-19) with its release checksum. Upgrades = bump the pin +
   re-vet, per llm-gateway.md.
7. **Keep FileVault; accept manual unlock after unplanned reboots.**
   Verified 2026-07-21: **FileVault is On** on the mini, `autoLoginUser` is
   unset, `pmset autorestart` is already 1, system sleep is 0. FileVault
   makes auto-login impossible (macOS disallows the combination), and an
   unplanned reboot halts at the pre-boot unlock screen where **nothing**
   runs — no tailscaled, no SSH, no LaunchAgents. Posture: planned reboots
   use `sudo fdesetup authrestart` (one-time unlocked reboot). **CORRECTED
   by reboot test #1 (2026-07-21): authrestart lands at the loginwindow,
   not in a logged-in session** — the FileVault→login passthrough only
   applies to a _physical_ pre-boot unlock, and authrestart skips that
   screen, so there is no auth event to pass through. What authrestart
   actually buys: the disk is unlocked and **system daemons (incl.
   tailscaled → tailnet SSH) come up without touch**; user LaunchAgents —
   and therefore the VMs — wait for one console login. Working posture:
   every reboot needs one console credential entry before the gateway
   returns; the dead-man check alerts if that's forgotten. Open
   improvement: test whether the container stack can be driven from an SSH
   session (boot script by hand post-authrestart) — if yes, planned
   reboots become remotely recoverable with no console touch. Rejected alternative: disabling FileVault + auto-login
   buys no-touch for all reboot causes at the cost of at-rest encryption on
   the disk holding the subscription tokens — wrong trade for a
   token-custody appliance. **This posture supersedes the "enable
   auto-login" step in the iv-sandbox reboot-resilience TODO item**, which
   predates knowing FileVault is on and is unachievable as written.

## Host-fragility posture (answers "what silently breaks unattended AC VMs")

The two macOS-GUI-only settings from apple-container-vms.md (auto-login, App
Data Protection/Full Disk Access for the container helpers) cannot be set,
or reliably kept set, from the CLI. The plan treats them as a **drift class**
and addresses them three ways:

- **Verify instead of assume.** The repo ships `host/check-host-gates.sh`:
  asserts `pmset autorestart` = 1, FileVault is On with
  `DisableFDEAutoLogin` unset, `container system` responds within a timeout, and a
  throwaway `machine run … true` completes (an XPC-timeout here is the
  fingerprint of a revoked/pending ADP grant — the only reliable probe,
  since TCC.db is SIP-protected). The boot LaunchAgent runs it at every
  login and logs; it's also the first runbook step on any alert.
- **Alert on the failure, not the setting.** Whatever gets past the gates,
  the in-VM dead-man check goes DOWN when the VM doesn't come up. Every
  GUI-setting failure mode degrades to "alert + runbook", never to silence.
- **Rituals for the events that revoke grants.** TCC grants are tied to the
  helper binaries, so a `container` cask upgrade can silently re-trigger the
  ADP prompts — the next boot then hangs with an XPC timeout. Rule: **never
  auto-upgrade the `container` cask**; upgrades are a console ritual
  (upgrade → boot a VM → answer any prompts → `check-host-gates.sh` →
  authrestart acceptance test), same spirit as the tailscale brew ritual in
  CLAUDE.md. macOS major updates get the same post-update verification.

## Execution model — operator touchpoints and delegation

**Operator touchpoints (the only steps an agent cannot do).** Everything not
listed here is agent-executable from documented state; the agent drives the
migration and requests these four at the moments they're needed:

1. **Console GUI (Phase 0):** grant App Data Protection / Full Disk Access
   to the container helpers in System Settings — TCC is not scriptable.
2. **FileVault password (Phases 0 & 4):** `sudo fdesetup authrestart`
   prompts interactively (run it via the `!` prefix or at the console), and
   the power-loss drill ends at a console unlock.
3. **healthchecks.io project (Phase 4):** creating the new `llm-gateway`
   project + its API key is dashboard-only; the checks inside it are then
   API-created by the agent.
4. **OAuth browser approvals:** only if the copied-token contingency fires
   (decision 3).

**Delegation tiers** (H = Haiku, S = Sonnet, ★ = session model; per the
global rule, delegate H/S units to subagents at that tier and verify their
claims against the files before acting):

| Unit                                                    | Tier | Self-checkable acceptance test                                                             |
| ------------------------------------------------------- | ---- | ------------------------------------------------------------------------------------------ |
| Phase 1 authoring (config tmpl, units, scripts, README) | S    | `shellcheck` + `bash -n`; `plutil -lint` the plist; secret-grep clean; ★ review pre-commit |
| Phase 2 VM build/provision                              | ★    | Host-state sensitive; TTY-wrapper gotchas — inline                                         |
| Phase 2 path-shape probe matrix                         | S    | Fixed matrix of request shapes → recorded status/body per row                              |
| Phase 3 credentials                                     | ★    | Secrets in play — **never** hand tokens, api-keys, or the access token to a subagent       |
| Phase 4 healthcheck wiring + timer                      | S    | Timer fires; check pings green; `/fail` path exercised once                                |
| Phase 4/0 reboot tests                                  | ★    | Operator present anyway (touchpoint 2)                                                     |
| Phase 5 per-consumer repointing                         | H/S  | One subagent per VM; completion succeeds via the new URL; ★ spot-verifies                  |
| Phase 6 teardown                                        | ★    | Destructive — inline, with pre-delete inspection                                           |
| Phase 6 doc rewrites                                    | S    | Prettier clean; links resolve; ★ review pre-commit                                         |

## Phase 0 — prerequisites (host)

- [ ] Verify `DisableFDEAutoLogin` is not set (decision 7); write the
      power-loss recovery runbook stub (console unlock → confirm check
      recovery).
- [ ] Grant App Data Protection / Full Disk Access to the container helpers
      (`container-runtime-linux`, `container-apiserver`) at the console and
      confirm the grants survive a reboot.
- [ ] ~~`pmset autorestart 1`~~ — already set (verified 2026-07-21).

**Gate:** `sudo fdesetup authrestart`, then `script -q /dev/null container
machine run -n iv-sandbox true < /dev/null` succeeds with no touch of the
mini after the command is issued.

## Phase 1 — the repo

Create `kylelundstedt/llm-gateway` (private) containing:

- [ ] `config/cli-proxy-api.yaml.tmpl` — hardened template, derived from the
      live host config `~/.config/iv-sandbox/cli-proxy-api.yaml` (the source
      of truth for the yaml schema — don't guess key names): bind
      `127.0.0.1:8317`, required `api-keys` (placeholder), control panel +
      auto-update + plugins + usage stats off. Carry the hardening checklist
      from llm-gateway.md as comments so it survives upgrades. Include the
      `oauth-model-alias` entries for `gpt-5.3-codex` / `gpt-5.2-codex` /
      `gpt-5.4-nano` (folds in TODO.md's polish item).
- [ ] `systemd/cli-proxy-api.service` — runs as `exedev`, `Restart=always`,
      reads config from `/home/exedev/.config/llm-gateway/`.
- [ ] `provision.sh` — idempotent, run as root in the guest: download +
      checksum-verify the **pinned** CLIProxyAPI arm64 release, install units,
      enable tailscaled, apply the exeuntu fixups (mask
      `systemd-growfs-root.service`), install the healthcheck timer. No
      secrets in the repo; token files and api-key are placed by hand per the
      runbook.
- [ ] `healthcheck/` — script + systemd timer (~5 min): probe
      `127.0.0.1:8317/v1/models` with the api-key **and** check
      token-file freshness (age of last refresh / expiry field) so a dead
      upstream credential can't hide behind a live port (monitoring.md:
      probes must cover dependencies). Ping the healthchecks.io check URL
      from `/etc/llm-gateway/healthchecks.env` (not committed); `/fail` on
      probe failure.
- [ ] `host/` — the two host-side components, versioned here rather than
      hand-managed: the **boot LaunchAgent** plist (RunAtLoad:
      `check-host-gates.sh`, then `container system start` + `machine run …
true`, with one bounded retry through `container system stop && start`
      to absorb the known first-use race and post-reboot bridge desync) and
      **`check-host-gates.sh`** (see "Host-fragility posture"), plus an
      install snippet.
- [ ] `README.md` — runbooks: build/provision, credential seeding, in-VM
      OAuth re-login (SSH `-L` callback forwarding), token rotation, upgrade
      (bump pin + re-vet), the **`container` cask upgrade ritual** and
      **power-loss recovery** (console unlock, then verify the check
      recovers), and the ToS-gray-zone caveat copied from llm-gateway.md.

**Gate:** repo review — no secrets committed, provision.sh is idempotent by
inspection.

## Phase 2 — build the VM

Per apple-container-vms.md, all guest exec via the `script -q /dev/null …`
TTY wrapper:

- [ ] `container machine create ghcr.io/boldsoftware/exeuntu:latest --name
llm-gateway --cpus 2 --memory 2G --home-mount none`
- [ ] Boot; gate on `systemctl is-system-running` = `running` (after masking
      growfs per provision.sh).
- [ ] Clone the repo in the guest; run `provision.sh`.
- [ ] Join the tailnet: mint a one-use `tag:dev` key via the Tailscale OAuth
      client (secrets.md), `tailscale up --authkey=… --hostname=llm-gateway
--accept-dns`.
- [ ] **Path-shape verification** (decision 1): with a temporary api-key,
      exercise the exact request shapes Shelley sends against bare
      CLIProxyAPI. Decide Caddy-free vs. thin in-VM Caddy; record the outcome
      in the repo README.

**Gate:** VM is `running`, on the tailnet as `llm-gateway`, service up with a
placeholder key; path-shape question answered.

## Phase 3 — credentials

- [ ] Copy `~/.cli-proxy-api/codex-*.json` and `claude-*.json` from the host
      into the guest (`base64` through the exec wrapper), owner `exedev`,
      dir 0700 / files 0600. **Do not delete the host copies yet** — they are
      the rollback path until Phase 6.
- [ ] Mint the new gateway access token; set it as the CLIProxyAPI api-key in
      the guest config. Record it where consumers' provisioning can read it
      (1Password, alongside the old token's home).
- [ ] Restart the service; confirm both providers refresh and serve:
      `curl -H "Authorization: Bearer <new-token>"
http://127.0.0.1:8317/v1/models` from inside the guest lists Claude and
      GPT models.
- [ ] One real end-to-end completion per provider (smallest model, one
      sentence) — a models list can succeed on a stale token.

**Gate:** both providers answer a live completion through the VM.

## Phase 4 — serve, boot, monitoring

- [ ] `tailscale serve --bg https+insecure=443 → http://127.0.0.1:8317` (or
      the in-VM Caddy port if Phase 2 said so). From another tailnet node:
      models list + one completion against
      `https://llm-gateway.dojo-sun.ts.net` with the new token.
- [ ] Install the repo's `host/` boot LaunchAgent (gate check + boot +
      bounded self-heal retry); extend or share it with iv-sandbox's boot so
      both machines come up.
- [ ] Create the healthchecks.io check in a new `llm-gateway` project
      (period/grace sized per monitoring.md rules — grace > probe interval;
      suggest period 300 s, grace 900 s); drop the ping URL into
      `/etc/llm-gateway/healthchecks.env`; confirm the timer pings green.
- [ ] **Reboot acceptance test, run twice:** `sudo fdesetup authrestart`;
      with no further touch, a tailnet client gets a completion from
      `https://llm-gateway.dojo-sun.ts.net` and the check recovers green.
- [ ] **Power-loss drill (once):** plain `sudo reboot` to simulate
      an unattended halt at the FileVault unlock screen; confirm the check
      goes DOWN and alerts within its grace, then unlock at the console and
      confirm recovery with no other intervention.

**Gate:** double planned-reboot test passes; power-loss drill alerts and
recovers; check is green with real cadence.

## Phase 5 — cutover + burn-in

- [ ] Repoint consumers one at a time, verifying a completion after each:
      iv-sandbox's `shelley.json` (vmnet URL → tailnet URL + new token), then
      each tailnet/exe.dev VM (URL unchanged in shape, new host + new token).
- [ ] Old door goes quiet but **stays up** — Caddy access logs (or CLIProxyAPI
      request logs) confirm zero traffic on `:8443`/`:8484` after cutover.
- [ ] **Burn-in: 7 days** — spans sessions; record the start date and any
      incidents on the TODO item so a later session can judge the gate.
      Rollback at any point = repoint `shelley.json`s back to the old
      URLs/token; host stack is untouched until Phase 6. Watch specifically
      for: token-refresh failures (both files were _copied_ — first in-VM
      refresh is the real test), post-reboot serve/subnet desync, and check
      flapping.

**Gate:** 7 clean days — no manual restarts, no check alerts, no consumer
fallback.

## Phase 6 — teardown + docs

- [ ] Unload + delete host LaunchAgents `com.industryvault.iv-sandbox-cli-proxy`
      and `-llm-gateway`; remove the `tailscale serve --https=8443` mapping.
- [ ] Remove host Caddy config; uninstall brew Caddy if nothing else uses it.
- [ ] `rm -rf ~/.cli-proxy-api ~/.config/iv-sandbox/{cli-proxy-api.yaml,cpa-key.txt,Caddyfile,gateway-access-token.txt}`
      and the host `cli-proxy-api` binary; retire the old access token in
      1Password.
- [ ] Rewrite llm-gateway.md around the VM form (current-form section →
      history note); update hosts.md, TODO.md (close the migration + polish
      items), CHANGELOG.md; note the out-of-registry check in monitoring.md's
      scope section, mirroring the rss-feed entry.

**Gate:** old endpoints refuse connections; docs match reality;
`test-install.sh provisioning` still green (no manifest references to the
removed pieces).

## Execution log

**2026-07-21 — Phases 1–3 done, Phase 4 partial (paused on operator).**
Repo: `kylelundstedt/llm-gateway` (private). VM `llm-gateway` running
(192.168.64.5 / tailnet 100.127.121.69); gate results: Phase 2 `running` +
tailnet + 401-with-no-auth through the full chain; Phase 3 24 models served
and a live `GATEWAY-OK` completion from **both** providers via
`https://llm-gateway.dojo-sun.ts.net`. Copied tokens survived first in-VM
use. New access token minted + stored in 1P Employee vault
(`llm-gateway access token`, item `7qr3qlnfag3jl3tuuhemhqmnx4`). Boot
LaunchAgent installed; all five host gates PASS. Health **timer disabled**
pending the healthchecks.io ping URL (its final ping would fail every 5 min
and mark systemd degraded). Old host stack untouched (rollback path).

Findings folded back into the repos:

- **ADP prompts recur per new VM**, not per install — the first
  `machine create` boot XPC-timed-out until the fresh
  `container-runtime-linux` prompt for `llm-gateway` was approved live.
- **PTY mangles multi-line guest commands** (canonical-mode line limit);
  the single-line base64-tarball method is the only reliable transfer/exec
  path.
- **Caddy site address must be any-Host** (`http://:8318`); the documented
  original-gateway gotcha got reintroduced from spec and was caught by the
  tailnet 401 test (host-specific site = silent empty 200).
- **growfs mask isn't enough** — the unit fails before provision.sh masks
  it; `systemctl reset-failed` needed for `is-system-running` = `running`.
- **launchd PATH lacks `/usr/local/bin`** — host scripts must export PATH
  or the `container` CLI silently no-ops.
- **Healthcheck expiry grace = 24 h**: `expired` is the ~8 h access-token
  expiry and CLIProxyAPI refreshes on demand, so an idle gateway
  legitimately sits past it; only >24 h indicates a broken refresh.

**2026-07-21 (later) — monitoring live.** healthchecks.io project
`llm-gateway`, check `gateway-health` (period 300 s / grace 900 s) created
by operator; URL wired into `/etc/llm-gateway/healthchecks.env`; timer
enabled; healthcheck green (ExecMainStatus=0). Two healthcheck-script bugs
found on first live run, both jq-falsy footguns on `disabled: false`
(`jq -e` exits 1 on a false value; `//` substitutes on false too) — fixed
with a bare `jq -r` read + string test. The buggy runs pinged `/fail` for
real, exercising the DOWN→alert→UP cycle end to end. Email integration added to the project and BOTH alert emails confirmed received (deliberate drill). Reboot acceptance test #1 (authrestart) initiated by operator.

**2026-07-21 — reboot test #1: PASSED with a corrected model.**
`authrestart` (12:31 boot) landed at a **fresh loginwindow** — the
passthrough-login assumption in decision 7 was wrong (see correction
there). After ONE console login (12:32): boot agent fired, gates correctly
FAILed on the not-yet-started container system, self-heal started it,
VM up at 12:32:39, healthcheck green at 12:34 — inside grace, no false
alert. Both VMs recovered (guest vmnet IPs reassigned post-reboot; tailnet
addresses unaffected). Redefined pass criterion: reboot + one console
login + zero further intervention.

**2026-07-21 — reboot test #2: PASSED, remote recovery proven.** Boot
12:41:30; NO console login at any point (verified via `last` — SSH
sessions only). Tailnet SSH reachable from the mbp while the mini sat at
the loginwindow (authrestart disk-unlock confirmed). `boot-llm-gateway.sh`
run in the SSH session brought the full stack up — **the container stack
does not need a GUI session** — completion `SSH-RECOVERY-OK` +
healthcheck green. Planned reboots are therefore fully remotely
recoverable; console is only required after power loss. Limitations of
the pre-console-login state, all verified: (1) **op CLI dead** (1P
desktop-app integration needs the GUI app) — no secret reads; (2) **1P
SSH agent down** — commit signing fails (`-c commit.gpgsign=false` to
commit); (3) **GitHub push blocked** (SSH auth via 1P agent; PAT env
resolved from 1P at login; gh keyring token stale). iv-sandbox does NOT
come back in this path (its LaunchAgent needs console login) — boot it
manually via `container machine run`. One llm-gateway README commit
(verified reboot model) is committed locally, push pending console login.

Remaining, in order: power-loss drill (plain `sudo reboot` + operator
console unlock, expect DOWN alert within grace) → Phase 4 gate → Phase 5
cutover + 7-day burn-in → Phase 6 teardown. Phase 5 note: repointing is
done inline (★), not delegated — consumer updates carry the access token,
which never goes to a subagent.

## Risks

| Risk                                                     | Mitigation                                                                          |
| -------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| Copied OAuth tokens fail on first in-VM refresh          | In-VM re-login runbook (Phase 1); host stack still live until Phase 6               |
| Shelley path shapes need Caddy's routing                 | Explicit Phase 2 verification; thin in-VM Caddy fallback, config in repo            |
| FileVault halts unplanned reboots at pre-boot unlock     | Dead-man check alerts within grace; power-loss drill proves it; console runbook     |
| `container` cask upgrade silently revokes ADP/TCC grants | Never auto-upgrade the cask; console upgrade ritual + `check-host-gates.sh` after   |
| GUI-setting drift (loginwindow, grants) between reboots  | `check-host-gates.sh` at every login via the boot agent; first runbook step         |
| Reboot leaves VM down (first-use race, bridge desync)    | Boot agent's bounded `system stop/start` retry; acceptance tests; dead-man backstop |
| Healthcheck green while a provider token is dead         | Probe checks token freshness, not just the port; per-provider completion in gates   |
| ToS/account-flag exposure (unchanged by migration)       | Same posture as today: personal-only, never in iv-image; metered keys for team use  |

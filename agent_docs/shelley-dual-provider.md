# Shelley dual-provider access (exe.dev OpenAI + personal-gateway Claude)

> Status: **CLOSED 2026-07-22 — verified but NOT to be built.** The design below
> works end to end (proven on two throwaway canaries, `gw-canary` and
> `merge-canary`, both deleted). It is retained as a technical record only.
> Do not implement it. Companion to [llm-gateway.md](llm-gateway.md) (the
> appliance) and [model-routing-economics.md](model-routing-economics.md).

## Why this is closed

Two findings on 2026-07-22, in this order:

1. **The premise is outside Anthropic's stated scope for subscription OAuth.**
   [Claude Code — Legal and compliance](https://code.claude.com/docs/en/legal-and-compliance):
   OAuth "is designed to support **ordinary use of Claude Code and other native
   Anthropic applications**"; limits "assume **ordinary, individual usage**";
   Anthropic "does not permit third-party developers … to route requests
   through Free, Pro, or Max plan credentials on behalf of their users"; and it
   "reserves the right to take measures to enforce these restrictions and may
   do so **without prior notice**." Docs tightened ~2026-02-19; enforcement
   against third-party tools using Pro/Max quota began 2026-04-04. Fanning a
   non-native client across seven VMs moves further from "ordinary, individual,"
   and a vendor-side block would take out Claude access fleet-wide with no
   warning.
2. **The goal was already met by a supported path.** The objective was "Claude
   available on every exe.dev VM." Running `claude` in a terminal is ordinary
   use of Claude Code — the native application — and is fully permitted. Claude
   Code is installed and individually logged in on the fleet already
   (`install.sh` distributes no credentials; each VM was logged in on its own).
   So Claude Max is available on every VM today with **zero** infrastructure: no
   merge proxy, no per-VM tokens, no service-account delivery, no dependency on
   the mini.

What the design would have added over that is Claude models inside **Shelley's
model picker** — a non-native client — which is exactly the part the policy
addresses. The residual gap is covered by the hybrid Claude Code → Shelley
handoff in [model-routing-economics.md](model-routing-economics.md), which is
now understood to be permanent rather than a stopgap.

**Still useful from this work:** the measured fact base below (exe.dev's `llm`
integration is OpenAI-only), the single-`llm_gateway`-slot constraint, the
`.ts.net`/bare-IP limits on `http-proxy` targets, and the verified 1Password
service-account delivery mechanism — that last one is generally applicable and
is referenced from [secrets.md](secrets.md).

## The problem (as it stood before the policy finding)

Claude Max quota is unreachable from Shelley on exe.dev VMs, and exe.dev
cannot fix that: per its integrations docs, **subscription backing exists only
for OpenAI** ("ChatGPT subscriptions are exclusively available for OpenAI on
personal integrations"). The Anthropic provider slot can be backed by the
exe.dev gateway (allocation, then metered) or a pay-per-token Anthropic API
key — never by Claude Max. The personal `llm-gateway` appliance is therefore
the only route from a Claude subscription into Shelley.

## Corrected fact base (measured 2026-07-22)

`ssh exe.dev integrations list` shows:

```
llm  llm  providers=openai(chatgpt:chatgpt)  tag:llm auto:all
```

Only the **openai** slot is configured, backed by the ChatGPT subscription,
attached to every VM. Confirmed by enumerating the integration directly from
inside a VM — `https://llm.int.exe.xyz/v1/models` returns **78 entries = 39
unique models × 2 naming forms** (bare and `openai/`-prefixed), **all OpenAI,
zero Anthropic**: `gpt-5.6-{sol,terra,luna}`, `gpt-5.5`, the `*-pro` variants,
the full o-series (incl. `o3-deep-research`, `o4-mini-deep-research`), back to
`gpt-4o`.

So today every exe.dev VM has 39 OpenAI models at **$0 marginal cost** and **no
Claude models at any price**.

## The constraint that shapes the design

`shelley.json` has exactly one `llm_gateway` key, and exe.dev's own
control-plane config already occupies it:

```json
{ "llm_gateway": "http://169.254.169.254/gateway/llm", ... }
```

A discovered integration **unconditionally preempts** a configured gateway.
Shelley says so directly (`shelley models` on a stock exe.dev VM):

```
Discovered exe.dev LLM integration  name=llm host=llm.int.exe.xyz models=39
Skipping LLM gateway because an exe.dev LLM integration was discovered
```

Two flags exist and are **not** interchangeable:

| Flag                       | Effect                                    |
| -------------------------- | ----------------------------------------- |
| `-disable-llm-integration` | Ignore the discovered exe.dev integration |
| `-disable-gateway`         | Ignore `llm_gateway` from shelley.json    |

Naively pointing `llm_gateway` at the personal appliance is therefore a no-op
unless `-disable-llm-integration` is also set — and once set, the VM loses all
39 exe.dev models. The two sources are not additive.

## The design: a VM-local merging proxy

Make one URL serve both providers. Caddy runs on the VM, `llm_gateway` points
at loopback, and each provider prefix is routed to its own upstream:

```
{
	admin off
	auto_https off
}
:8899 {
	handle /anthropic/* {
		reverse_proxy https://llm-gateway.dojo-sun.ts.net {
			header_up Host llm-gateway.dojo-sun.ts.net
		}
	}
	handle /openai/* {
		uri strip_prefix /openai
		reverse_proxy https://llm.int.exe.xyz {
			header_up Host llm.int.exe.xyz
		}
	}
	handle {
		respond "no route" 404
	}
}
```

Path shapes line up without translation: Shelley calls `{gateway}/anthropic/…`
and `{gateway}/openai/…`; the appliance's own Caddy strips `/anthropic`, and
`/openai` is stripped here so exe.dev sees its native `/v1/…`.

VM config: `{"llm_gateway":"http://127.0.0.1:8899"}` plus
`-disable-llm-integration` on Shelley's `ExecStart`.

## Verification (2026-07-22, `merge-canary`, x86_64)

| Layer               | Result                                                                    |
| ------------------- | ------------------------------------------------------------------------- |
| Proxy routing       | `/openai/v1/models` → 78 entries; `/anthropic/` → 200; unrouted → 404     |
| Shelley enumeration | Accepts loopback gateway; routes anthropic→`/anthropic`, openai→`/openai` |
| Completion — Claude | `claude-opus-4-8` → `…/anthropic/v1/messages` → `MERGE_ANTHROPIC_OK`      |
| Completion — OpenAI | `gpt-5.6-sol` → `…/openai/v1/responses` → `MERGE_OPENAI_OK`               |

Caddy 2.11.4, verified against the release's own `checksums.txt`. **Note:** the
llm-gateway repo pins only the **arm64** SHA512 (the appliance is arm64);
exe.dev VMs are **x86_64**, so an amd64 pin must be added before this is
provisioned rather than hand-run.

## Why a custom http-proxy integration cannot replace the local proxy

The obvious alternative — an exe.dev `http-proxy` integration holding the
gateway token, so no secret lands on the VM — **is blocked by exe.dev**:

```
--target=https://llm-gateway.dojo-sun.ts.net → "target URL must not use a .ts.net domain"
--target=https://100.127.121.69              → "target URL must use a hostname, not an IP address"
```

Consistent with the transport: `*.int.exe.xyz` resolves to `169.254.169.254`
routed via the VM's `eth0` gateway, i.e. the VM-side entry point to an
exe.dev-side egress that is not on the tailnet. Satisfying both guards would
require a **public** hostname (Funnel or a custom domain), which would put a
box holding live subscription OAuth tokens on the public internet behind one
shared bearer token. Rejected.

**Consequence: the gateway token must reach every participating VM.** That is
the real cost of this design.

## Open items (all gating)

1. **Per-VM gateway tokens.** CPA's `api-keys` is a list — issue one token per
   VM rather than fan out one shared token to seven. Converts a compromise
   from "rotate everything" to "revoke one VM." The rotation runbook in the
   llm-gateway repo README assumes a single shared token and needs revising.
2. **Token delivery — mechanism VERIFIED 2026-07-22** (spike on canary
   `op-spike`, deleted; see "1Password service-account delivery" below).
   Plaintext `EnvironmentFile` (iv-sandbox's current pattern) does not scale to
   the fleet; `op run --env-file` under a per-project service account does, and
   fails closed. Still trades the gateway token for an SA token on the VM — the
   gain is central revocation and no gateway secret at rest, not elimination.
3. **`-disable-llm-integration` is a silent-failure surface.** Omit it and the
   VM quietly reverts to OpenAI-only with no error. Needs a healthcheck
   assertion, not just a provisioning step.
4. **Phantom models.** Shelley builds its picker from a built-in catalog, not
   from what the gateway serves, so `grok-4.5` and the `*-fireworks` family
   appear and fail (404 at the merge proxy — clean, but the picker still
   lies). Adding a `/fireworks/*` route would make them real if that slot is
   ever enabled on the exe.dev integration.

## 1Password service-account delivery (spike, 2026-07-22)

Verified on the mini and on a bare exeuntu canary (`op-spike`, x86_64, both
since deleted). Test SA scoped read-only to a single `gitlake-spikes` vault.

| Gate                                | Result                                                                                   |
| ----------------------------------- | ---------------------------------------------------------------------------------------- |
| Plan supports service accounts      | ✅ `User Type: SERVICE_ACCOUNT`; SA sees exactly the one granted vault                   |
| `op run --env-file` non-interactive | ✅ resolves with only `OP_SERVICE_ACCOUNT_TOKEN` — no desktop-app integration needed     |
| systemd `ExecStart` wrapping        | ✅ `ExecStart=/usr/local/bin/op run --env-file=… -- <binary>`; child sees resolved value |
| Fails closed                        | ✅ see below                                                                             |

**Fails closed, which is the important property.** Missing `EnvironmentFile`
→ systemd refuses the job outright and the unit never executes. Bad secret
reference → `op` exits 1 with a precise journal line (`could not find item … in
vault …`) and the service fails. Restoring either recovers on the next start.
In neither case does the service come up with an empty or unresolved secret.

Gotchas worth carrying into any implementation:

- **Service accounts require an explicit `--vault`** on `op item get`
  (`a vault query must be provided when this command is called by a service
account`). Scripts written against a normally signed-in `op` will break.
- `install.sh`'s existing Linux `op` install path works unchanged on x86_64
  (v2.35.0 at time of test) — VMs need no new provisioning to support this.
- Do **not** store an SA's own credential item in the vault that SA can read
  (the test setup did; that was 1Password's default placement, not a design
  choice).

**Not directly proven: rotation.** The test SA was read-only, so no secret
value could be changed and observed. Indirect evidence is strong — changing the
_reference_ took effect on the very next service start, and an invalid one
failed at start, so resolution happens per process start rather than at install
time. "Update the 1P item, restart the service" follows, but deserves one
direct confirmation against a writable item before it is relied on.

## Failure domain

Split, which is an improvement over an all-or-nothing flip: if the mini is
down (power loss halts at FileVault pre-boot — see
[llm-gateway-migration.md](llm-gateway-migration.md)), the Claude half breaks
and the OpenAI half keeps working. The fleet degrades rather than goes dark.

## Corrections this work forces elsewhere

- **`model-routing-economics.md`** states "Fable, Opus, and Sonnet selected
  inside Shelley are exe.dev-managed API models: they consume the limited
  included exe.dev Shelley allocation and then metered spend." Measured false
  as of 2026-07-22 — the Anthropic slot is unconfigured, so those models are
  not selectable at any price. The doc describes the exe.dev-gateway backing
  option, which is not in force.
- **`exe-dev` skill** — its "Setting Up a Dev VM" section documents a
  registered `new.setup-script` default that auto-joins Tailscale and runs
  `install.sh`. `defaults read dev.exe new.setup-script` returns `(not set)`;
  the 2026-07 flip to on-demand `/join-tailnet` was never reflected. Following
  that section produces a VM waiting on a bootstrap that never runs.
  [exe-dev.md](exe-dev.md) already records the no-hook contract correctly — the
  skill is the stale copy, and it is the one agents read before touching the
  platform.

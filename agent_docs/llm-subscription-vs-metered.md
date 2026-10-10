# LLM subscriptions vs. metered API keys (2026-10-09)

Measured comparison of what the fleet's actual model usage would cost at
metered API list prices, against the two subscriptions it runs on today. It
was written to decide how the Aperture gateway rollout should authenticate:
subscription passthrough (per-VM login) or metered keys held by Aperture (no
login). Refresh the numbers before changing any plan; the method is at the end.

## Verdict

- **Subscriptions are far cheaper than metered keys for this usage.** At list
  API prices the 10-week window (Aug 1 – Oct 9) comes to **$3,975**, about
  **$1,700/month**, against **$300/month** for Claude Max 5x ($100) plus
  ChatGPT Pro 200 ($200). Even the quietest stretch (the last two weeks) runs
  about $570/month at API prices.
- **But $1,478 of that relies on a path Anthropic prohibits** — see "The
  Shelley-on-Claude caveat". Without it, Claude usage is Claude Code alone
  (about $180–$400/month at API prices), which still favours Max 5x.
- **Claude:** keep Max 5x. Its $100/month of API credits are linked to
  "Kyle's Individual Org" (2026-10-10). They cover the API, Agent SDK, Batch
  API, Playground and Managed Agents — **not Claude Code** — and expire each
  cycle, so they fund metered API use only.
- **ChatGPT:** keep Pro 200 at least through 2026-12-31. The 62,500-credit grant
  ($2,500) exceeds the whole 10-week GPT total ($2,058), so it should absorb any
  overflow after the allowance halves on 2026-10-30. Review in December.

## What the two plans include

| Plan                          | Price   | Included                                                                                                                                                                                                                                                                                                                                                                                                                              |
| ----------------------------- | ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Claude Max 5x (renews 13th)   | $100/mo | 5x Pro usage per 5-hour session plus a weekly cap, shared by Claude and Claude Code. **Plus $100/mo of API credits** ([docs](https://platform.claude.com/docs/en/about-claude/api-credits-for-subscribers)): link one Console org (Owner/Admin/Billing role; only support can change the link), no rollover, any Claude API model via any API key in that org. Excluded: Claude Code (as subscription usage), Bedrock/Vertex/Foundry. |
| ChatGPT Pro 200 (renews 25th) | $200/mo | Codex + ChatGPT Work at 20x Plus until 2026-10-29, then **10x Plus** from 2026-10-30; no 5-hour limit. One-time grant of 62,500 usage credits ($2,500), expiring 2026-12-31. Codex is metered in credits at 25 credits = $1, the same rates as the API ([rate card](https://learn.chatgpt.com/docs/pricing)). No OpenAI API platform credits included.                                                                                |

Claude credits as granted (Console → Billing, 2026-10-10): $100.00
promotional credit, "Applies to: Agent SDK, API, Batch API, Playground, Managed
Agents", granted 2026-10-10, expires 2026-10-16 (UTC). The same page says
_purchased_ credits cover Claude Code; this promotional grant does not, so
Claude Code on a key from this organization would bill the purchased balance
($0). The first grant's six-day life looks prorated to the cycle; confirm the
next grant's dates after the 2026-10-13 renewal.

Unverified: whether the ChatGPT grant survives a plan change. Check before
relying on it.

## Measured usage at API list prices

Source: the AgentsView collector's raw mirrors on `iv-agentsview` (all 21
hosts, including the mini: Shelley `shelley.db` plus Claude Code and Codex
session logs), plus klundstedt-mbp's local logs. Window Aug 1 – Oct 9.

| Provider  | Source      | 10 weeks   | /month (10-wk avg) | September | /month (last 2 wks) |
| --------- | ----------- | ---------- | ------------------ | --------- | ------------------- |
| Anthropic | Shelley     | $1,478     | $642               | $267      | $53                 |
| Anthropic | Claude Code | $440       | $191               | $398      | $178                |
| OpenAI    | Shelley     | $2,045     | $888               | $222      | $341                |
| OpenAI    | Codex CLI   | $14        | $6                 | $12       | $0                  |
| **Total** |             | **$3,975** | **$1,726**         | **$899**  | **$572**            |

Shelley is about 90% of the total. Its GPT traffic went through exe.dev's
`llm.int.exe.xyz` (ChatGPT subscription integration; $2,033) and a little
direct to `chatgpt.com` ($12). Its Claude traffic went direct to
`api.anthropic.com` ($1,478).

Usage is bursty. Peak weeks: $966 Anthropic (week of Aug 17), $931 OpenAI (week
of Aug 10). September weeks ran about $110–$200 Anthropic and $30–$80 OpenAI.
The median active day was about $37; 16 of 61 active days exceeded $100 and 15
were under $10.

## The Shelley-on-Claude caveat

The fleet's Shelley is the `aifoundry-org/shelley` fork pinned by iv-provision.
Its Anthropic provider logs in with Claude Pro/Max OAuth using Claude Code's
client ID and prepends the "You are Claude Code…" identity the API requires for
subscription tokens (`llm/oauth/anthropic.go`, `llm/ant/authorizer.go`;
`shelley login anthropic` prints a terms warning). Nine VMs used it, 9,796 calls
from 2026-08-12 to 2026-10-09.

[model-routing-economics.md](model-routing-economics.md) ("Why this is
permanent") records Anthropic's terms: subscription OAuth is for "ordinary use
of Claude Code and other native Anthropic applications", third parties may not
"route requests through Free, Pro, or Max plan credentials", and enforcement
may come "without prior notice". Shelley is not a native Anthropic application.
So this usage cannot be counted as a durable subscription benefit.

**Decision (Kyle, 2026-10-09):** Aperture carries Claude Code and Codex CLI
traffic everywhere, on each client's own subscription login. The modified
Shelley keeps its subscription logins and stays outside Aperture for now,
accepting the risk above. If it is cut off, the fallbacks are a metered key
(the Max API credits cover the API) or no Claude in Shelley.

The OpenAI side has no equivalent problem: exe.dev's integration and the fork's
`shelley login openai` both use OpenAI's device-code flow for ChatGPT accounts.

## Pricing assumptions

Current list rates, $ per million tokens (input / 5-minute cache write / cache
read / output), from
[Anthropic](https://platform.claude.com/docs/en/about-claude/pricing) and
[OpenAI](https://developers.openai.com/api/docs/pricing):

- Fable 5.1: 10 / 12.50 / 0.25 / 50. Opus 5.5: 4 / 5 / 0.20 / 20. Opus 4.8: 5 / 6.25 / 0.50 / 25. Sonnet 5.5: 2 / 2.50 / 0.10 / 10.
- GPT-6.1 Sol: 2 / 2.50 / 0.10 / 10. GPT-6 Sol: 2 / 2.50 / 0.20 / 10. GPT-6 Astra (credit rate card): 10 / – / 1 / 50.

Stand-in rates, covering about $2,400 of the total: models no longer listed
were priced as their nearest current model — `gpt-5.6-sol` and `gpt-5.6-terra`
as GPT-6 Sol, `gpt-5.6-luna` as GPT-6 Luna, Opus 5 as Opus 5.5 (if Opus 5 was
priced like Opus 4.8, its $704 rises about 25%), Fable 5 as Fable 5.1, Sonnet 5
as Sonnet 5.5. Unpriced and negligible: Fireworks GLM/Kimi (68 calls) and one
local Qwen call.

Other limits:

- Claude Code deletes local logs after 30 days by default, so August's Claude
  Code figure is likely undercounted.
- Codex CLI session totals are attributed to the session's start time.
- These are what metered keys would cost. They do not show how close usage came
  to either subscription's own caps.

## Method (to refresh)

1. Copy the collector's mirrors (no `rsync` on the VM; use tar):
   `ssh iv-agentsview.exe.xyz 'cd ~/.agentsview/remote-mirrors && find . \( -path "*shelley/shelley.db*" -o -name "*.jsonl" \) -print0 | tar --null -czf - -T -' | tar -xzf - -C <dir>`
2. Shelley: attach each `shelley.db` with DuckDB's `sqlite` extension and read
   `messages.usage_data` (JSON with `input_tokens`, `cache_creation_input_tokens`,
   `cache_read_input_tokens`, `output_tokens`, `model`, `url`) for
   `type='agent'`. Deduplicate on `message_id`, because renamed VMs appear twice
   in the mirrors. For both providers `input_tokens` excludes cached tokens
   (Anthropic convention).
3. Claude Code: `type='assistant'` lines, `message.usage`, deduplicated on
   `message.id` (streaming repeats a message).
4. Codex: the last `event_msg` of `type='token_count'` per rollout file;
   `total_token_usage.input_tokens` includes `cached_input_tokens`, so subtract.
5. Join to a price table and sum. In DuckDB, use `json_extract(...)` rather
   than `->` on JSON columns inside `max_by`/`filter`, where `->` can parse as
   a lambda.

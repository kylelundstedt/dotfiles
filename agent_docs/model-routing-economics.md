# Model Routing and Subscription Economics

Decision record for using multiple model families economically in Shelley and
adjacent agent harnesses. Pricing and the usage snapshot below are dated
2026-07-19 and should be refreshed before changing subscriptions.

## Current subscriptions and constraints

- ChatGPT $100/month tier is connected to exe.dev and works as Shelley's
  OpenAI provider. Calls through this subscription record `$0` marginal cost
  in Shelley's usage data.
- Claude Max 5x is $100/month. Claude Fable 5 is the preferred model for
  difficult planning, but heavy use reaches Claude's subscription limits every
  few days.
- **Claude Max quota is not available to Shelley, and cannot become
  available** (see "Why this is permanent" below). Using Fable through Claude
  Code is a separate harness and requires an explicit cross-harness handoff; it
  must not be counted as a Shelley subscription benefit.
- **Correction 2026-07-22:** an earlier version of this doc said Fable, Opus,
  and Sonnet inside Shelley are exe.dev-managed API models drawing on the
  allocation then metered spend. Measured false — the `llm` integration is
  `providers=openai(chatgpt:chatgpt)` only, so `https://llm.int.exe.xyz/v1/models`
  returns 39 unique models, **all OpenAI, zero Anthropic**. Claude models are
  not selectable in Shelley on exe.dev VMs at any price. Enabling them means
  configuring the integration's Anthropic slot (exe.dev gateway or an Anthropic
  API key) — both metered.
- The existing exe.dev plan includes a monthly Shelley-token allocation.
  Managed usage beyond that allocation is metered at the gateway's published
  per-token prices without markup.

## Current recommendation

There are two distinct workflows; do not mix their accounting.

### Shelley-native workflow

1. Use `gpt-5.6-sol` through the ChatGPT subscription for planning, strategic
   evaluation, and routine verification. This is the only currently connected
   frontier subscription with zero marginal Shelley cost.
2. Use a cheaper capable model for implementation and tool-heavy execution:
   - Prefer a Z.ai GLM Coding Plan if execution volume is high and predictable.
   - Use exe.dev-managed GLM 5.2 on Fireworks or Claude Sonnet 5 for metered
     pilots, selective execution, overflow, and tie-breaking.
3. Use exe.dev-managed Fable or Opus only for bounded, high-value escalations.
   They are not covered by Claude Max when called from Shelley.
4. If GLM is only a reviewer, start with Z.ai Lite monthly. If it becomes a
   co-primary execution model or sustained overflow path, Z.ai Pro is the more
   plausible tier. Do not start with Z.ai Max or an annual commitment.

### Hybrid Claude Code → Shelley workflow

1. Use Fable through Claude Code under Claude Max to write a durable execution
   brief in the repository.
2. Hand that artifact to Shelley explicitly.
3. Use `gpt-5.6-sol` in Shelley for adversarial review and reconciliation.
4. Use GLM or managed Sonnet in Shelley for execution, followed by GPT review.

The hybrid workflow leverages Claude Max but is not an all-Shelley pipeline.
There is no way to have both Fable planning inside Shelley and Claude Max
economics — and this is the permanent shape, not a stopgap.

### Why this is permanent (2026-07-22)

A supported Claude-subscription provider inside Shelley is precisely what
Anthropic prohibits third parties from building.
[Claude Code — Legal and compliance](https://code.claude.com/docs/en/legal-and-compliance):

> **OAuth authentication** is intended exclusively for purchasers of Claude
> Free, Pro, Max, Team, and Enterprise subscription plans and is designed to
> support **ordinary use of Claude Code and other native Anthropic
> applications**.

> **Anthropic does not permit third-party developers to offer Claude.ai login
> or to route requests through Free, Pro, or Max plan credentials on behalf of
> their users.**

> Advertised usage limits for Pro and Max plans assume **ordinary, individual
> usage of Claude Code and the Agent SDK**. … Anthropic reserves the right to
> take measures to enforce these restrictions and may do so **without prior
> notice**.

The docs were tightened around 2026-02-19 and enforcement against third-party
tools using Pro/Max quota began in earnest on 2026-04-04. This is also the
answer to "why does exe.dev have a ChatGPT subscription integration but no
Claude one" — OpenAI ships a sanctioned device-code flow for ChatGPT accounts;
Anthropic offers no third-party equivalent, and building one would make exe.dev
the prohibited case verbatim.

**The line is drawn at the client, not the machine.** Running `claude` in a
terminal on an exe.dev VM is ordinary use of Claude Code — the native
application — and is fully supported. Claude Code is already installed and
individually logged in on the fleet, so **Claude Max is available on every VM
today** without any additional infrastructure. What is not available, and will
not be, is Claude models inside Shelley's own model picker. That gap is the
reason the hybrid handoff above exists.

## Evidence: GPT-5.6 Sol versus Fable 5

As of 2026-07-19, the best public independent comparison is Artificial
Analysis. Its results support treating the models as peers overall, with
different strengths rather than assuming Fable is categorically superior.

| Evaluation                    | GPT-5.6 Sol max |  Fable 5 max | Interpretation                    |
| ----------------------------- | --------------: | -----------: | --------------------------------- |
| Intelligence Index v4.1       |              59 |           60 | Effectively tied overall          |
| Agentic Index                 |              54 |           53 | Effectively tied; slight Sol lead |
| Coding Agent Index            |              61 |           59 | Slight Sol/Codex lead             |
| DeepSWE                       |             69% |          66% | Sol/Codex lead                    |
| Terminal-Bench v2             |             88% |          83% | Sol/Codex lead                    |
| SWE-Atlas-QnA                 |             27% |          29% | Fable/Claude Code lead            |
| Coding-agent API cost/task    |           $7.08 |       $11.72 | Sol cheaper                       |
| Coding-agent active time/task |        10.2 min |     23.4 min | Sol faster                        |
| GDPval-AA v2 Elo              |        1743 ±19 |     1760 ±19 | Statistical tie                   |
| AA-Briefcase Elo              |        1496 ±12 | 1583 -15/+16 | Clear Fable lead                  |

AA-Briefcase is particularly relevant to planning and professional deliverables.
Fable's lead includes stronger rubric adherence and analytical quality; the
launch analysis reported a 56% rubric score versus Sol's 42%, and analytical
quality Elo of 1764 versus 1592. Sol performed better on presentation quality.
This suggests Fable's most defensible current advantage is rigorous,
requirements-complete knowledge work rather than a broad intelligence gap.

Important limitations:

- The coding comparison is **Codex + Sol versus Claude Code + Fable**, not bare
  models in an identical scaffold. Harness tools, prompts, iteration policy,
  caching, and stopping behavior materially affect the result.
- The Fable configuration uses adaptive max reasoning with an Opus 4.8
  fallback, so it is not a pure Fable-only measurement.
- OpenAI reports a much larger Sol lead on its Agents' Last Exam evaluation
  (52.7% versus 40.5%), but that is vendor-reported evidence and should carry
  less weight than a matched independent evaluation.
- METR could not produce a robust software-task time-horizon estimate for Sol:
  its detected benchmark-environment exploitation rate was higher than for any
  public model METR had tested in its ReAct harness. This is a caution about
  autonomous-agent reliability and evaluation interpretation, not proof that
  ordinary Sol coding results are invalid.
- Paired public build tests remain anecdotes. One same-prompt test found Sol
  substantially cheaper and faster, but the author shipped Fable's result
  because Claude Code used browser feedback to verify and refine the visual
  output while Codex did not. This illustrates the harness confound directly.

Sources:

- [Artificial Analysis model comparison](https://artificialanalysis.ai/models/comparisons/gpt-5-6-sol-vs-claude-fable-5)
- [Artificial Analysis coding-agent comparison](https://artificialanalysis.ai/agents/coding-agents/comparisons/claude-code-vs-codex)
- [AA-Briefcase](https://artificialanalysis.ai/evaluations/aa-briefcase)
- [GDPval-AA v2](https://artificialanalysis.ai/evaluations/gdpval-aa)
- [OpenAI GPT-5.6 release evaluations](https://openai.com/index/gpt-5-6/)
- [METR predeployment evaluation](https://metr.org/blog/2026-06-26-gpt-5-6-sol/)
- [Lawrence Wu paired build](https://lawrencewu.net/posts/2026-07-09-fable-vs-sol-bible-kg/)

Operational conclusion: use Sol as the default Shelley planner without assuming
a major capability sacrifice. Reserve external Claude Code/Fable planning for
work where requirements completeness, analytical rigor, or the expected cost
of a missed constraint is unusually high. Validate this routing on the user's
own tasks because the public data does not isolate planning quality cleanly.

## 2026-07-19 initial Shelley baseline

The local Shelley database was newly created at 22:22 UTC on 2026-07-18, so
there is not yet a full-day or full-week history. A snapshot at approximately
01:54 UTC on 2026-07-19 contained:

- 293 paid-provider-shaped LLM requests, all covered by the ChatGPT
  subscription
- 6,492,483 non-cached input tokens
- 7,214,976 cache-read tokens
- 125,383 output tokens
- `$0` recorded marginal cost

Applying the 2026-07-19 exe.dev gateway rates to exactly that initial workload
shape gives this first-order counterfactual:

| Candidate execution model                | Initial 3.5-hour workload cost |
| ---------------------------------------- | -----------------------------: |
| exe.dev-managed Claude Fable 5           |                   about $78.41 |
| exe.dev-managed Claude Opus 4.8          |                   about $39.20 |
| exe.dev-managed Claude Sonnet 5          |                   about $16.40 |
| GLM 5.2 on Fireworks                     |                   about $11.52 |
| Grok 4.5                                 |                   about $17.34 |
| GPT-5.6 Sol through managed API          |                   about $39.83 |
| GPT-5.6 Sol through ChatGPT subscription |                    $0 marginal |

Do not extrapolate this short, unusually active setup session linearly to a
month. Its value is as a concrete token-shape and per-heavy-session benchmark.
After the database contains at least one representative week, use the 168-hour
report for a meaningful subscription break-even comparison.

## How to evaluate exe.dev as a primary model source

Use two levels of measurement.

### 1. Counterfactual screening

Run:

```bash
./shelley-cost-report --hours 24
./shelley-cost-report --hours 168
```

The tool reads Shelley's recorded usage, fetches current prices from the public
exe.dev gateway model catalog, and shows what the same token shape would cost
on representative managed models. For managed Claude models, this is gateway
list-price consumption: included exe.dev Shelley allocation may absorb it
before cash overage, but it is never Claude Max usage. It can also isolate one
conversation:

```bash
./shelley-cost-report --conversation <conversation-id> --hours 168
```

This answers whether a candidate is even economically plausible. It does not
capture behavioral differences between models.

### 2. Matched end-to-end task trial

For each candidate model, run the same representative task from the same git
commit and clean worktree. Include at least these task classes:

- thoughtful architecture/plan
- strategic adversarial review
- medium implementation with tests
- large tool-heavy implementation/refactor
- bug investigation with an initially uncertain cause

Record per trial:

- task completed correctly, including tests and cold review
- total recorded `cost_usd`
- elapsed time
- number of LLM requests and retries
- non-cached input, cache reads/writes, and output tokens
- human intervention required
- regressions or cleanup required after the model declared completion

The useful unit is **cost per accepted task**, not cost per million tokens:

```text
cost per accepted task = total model spend / accepted tasks

quality-adjusted cost = (model spend + estimated human correction cost)
                        / accepted tasks
```

A cheaper model that takes twice as many loops or creates cleanup work can be
more expensive than a stronger model.

## Routing experiments

Test both operationally valid versions rather than assuming Claude Max is
available inside Shelley.

### A. All-Shelley pipeline

1. **Plan and strategy — GPT-5.6 Sol:** produce architecture, invariants,
   risks, acceptance criteria, and an execution brief; then challenge and
   reconcile it in a separate review pass.
2. **Execution — Sonnet 5 or GLM 5.2:** implement from the reconciled brief,
   run tests, and report deviations rather than silently redesigning.
3. **Verification — GPT-5.6 Sol:** inspect the diff and test evidence.
4. **Selective escalation — managed Fable/Opus:** use only when risk or model
   disagreement justifies consuming exe.dev allocation or metered spend.

### B. Hybrid subscription pipeline

1. **Plan — Fable in Claude Code, outside Shelley:** write the execution brief
   to a committed or otherwise durable file.
2. **Strategic review — GPT-5.6 Sol in Shelley:** challenge the artifact and
   produce explicit amendments.
3. **Execution — Sonnet 5 or GLM 5.2 in Shelley:** implement the reconciled
   brief and run tests.
4. **Verification — GPT in Shelley:** use Fable in Claude Code again only for
   high-risk final review.

The hybrid handoff should pass a bounded artifact, not an entire chat transcript,
so Shelley's execution context stays economical and reproducible.

For either pipeline, compare two execution arms over at least 10 accepted tasks:

- exe.dev-managed Sonnet/Fireworks GLM, measuring exact `cost_usd`
- Z.ai GLM subscription, measuring quota consumption and interruptions

The break-even question is whether metered execution cost exceeds the Z.ai
monthly price while delivering comparable accepted-task quality. The initial
2026-07-19 workload repricing suggests managed Sonnet and Fireworks GLM could
exceed Z.ai Lite/Pro prices at sustained heavy volume, so the working
hypothesis is that exe.dev is best for selective high-value calls and model
diversity, while a flat-rate GLM plan is better for bulk execution.

## Revisit triggers

Re-evaluate this decision when any of these occur:

- a month of representative task/cost data is available
- Z.ai Lite interrupts work or consumes over 75% of weekly quota
- exe.dev managed-model spend exceeds $18/month or $72/month consistently
- Claude or ChatGPT changes subscription access, pricing, or model weighting
- Fable, Sonnet, GLM, GPT, or Grok pricing/quality changes materially
- Shelley gains direct Claude subscription authentication

# Model Routing and Subscription Economics

Decision record for using multiple model families economically in Shelley and
adjacent agent harnesses. Pricing and the usage snapshot below are dated
2026-07-19 and should be refreshed before changing subscriptions.

## Current subscriptions and constraints

- ChatGPT $100/month tier is connected to exe.dev and works as Shelley's
  OpenAI provider. Calls through this subscription record `$0` marginal cost
  in Shelley's usage data.
- Claude Max 5x is $100/month. Claude Fable 5 is the preferred primary model,
  but heavy use reaches Claude's subscription limits every few days.
- Claude Max cannot be selected directly as a Shelley provider. It remains
  usable through Claude Code, including when Shelley invokes Claude Code as an
  external process, but all Claude surfaces share the same subscription quota.
- The existing exe.dev plan includes a monthly Shelley-token allocation.
  Managed usage beyond that allocation is metered at the gateway's published
  per-token prices without markup.

## Current recommendation

1. Keep Fable 5 for thoughtful planning, architecture, and the hardest
   reasoning where its quality premium matters.
2. Use `gpt-5.6-sol` through the ChatGPT subscription for independent strategic
   evaluation and adversarial critique.
3. Use a cheaper capable model for implementation and tool-heavy execution:
   - Prefer a Z.ai GLM Coding Plan if execution volume is high and predictable.
   - Use exe.dev-managed Claude Sonnet 5, GLM 5.2 on Fireworks, or Grok for
     metered pilots, selective execution, overflow, and tie-breaking.
4. If GLM is only a reviewer, start with Z.ai Lite monthly. If it becomes a
   co-primary execution model or sustained Claude-overflow path, Z.ai Pro is
   the more plausible tier. Do not start with Z.ai Max or an annual commitment.
5. Use Claude Opus/Fable through the exe.dev gateway sparingly; their metered
   cost is poorly suited to sustained primary-agent volume.

This is a quality funnel rather than a rigid pipeline: expensive models decide
what to do and evaluate risk; cheaper models perform the token-heavy tool loop;
the planner or strategist reviews checkpoints and the final result.

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

| Candidate execution model | Initial 3.5-hour workload cost |
| --- | ---: |
| Claude Fable 5 | about $78.41 |
| Claude Opus 4.8 | about $39.20 |
| Claude Sonnet 5 | about $16.40 |
| GLM 5.2 on Fireworks | about $11.52 |
| Grok 4.5 | about $17.34 |
| GPT-5.6 Sol through managed API | about $39.83 |
| GPT-5.6 Sol through ChatGPT subscription | $0 marginal |

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
on representative managed models. It can also isolate one conversation:

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

## Routing experiment

Test the proposed pipeline on real work:

1. **Plan — Fable 5:** produce architecture, invariants, risks, acceptance
   criteria, and an execution brief. Stop before implementation.
2. **Strategic review — GPT-5.6 Sol:** challenge assumptions, identify missing
   cases, simplify the plan, and produce explicit amendments.
3. **Execution — Sonnet 5 or GLM 5.2:** implement from the reconciled brief,
   run tests, and report deviations rather than silently redesigning.
4. **Verification — GPT or Fable:** inspect the diff and test evidence. Reserve
   Fable for high-risk changes or disagreement; use GPT for routine gates.

Compare two execution arms over at least 10 accepted tasks:

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

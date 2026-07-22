# Agent Recommendations

How to operate Claude Code and Codex together effectively.

## Dual-Agent Patterns

### Draft and Cold Review

1. Claude drafts code/doc update.
2. Codex reviews cold for assumptions, edge cases, and clarity gaps.
3. Claude revises.
4. Repeat until both agents converge.

Best for: architecture docs, runbooks, API contracts, risky refactors.

### Parallel Hypothesis Debugging

1. Give both agents the same bug report and constraints.
2. Compare root-cause hypotheses.
3. Reconcile with logs/tests and pick one fix path.

Best for: intermittent bugs, cross-layer regressions.

### Second-Opinion Gate

Before merge on high-risk work:

- Request one adversarial review from the other model.
- Require at least one explicit "what could still fail?" pass.

## Task Routing

- Multi-file refactor: Claude primary, Codex reviewer
- Fast scaffolding/prototyping: Codex primary, Claude reviewer
- Documentation: Claude draft, Codex critique
- PR bug hunt: Codex first pass, Claude confirmation on architectural risks

Treat routing as default, not rigid policy.

## Agent Teams vs Dual Models

Agent teams (single-model parallelism) and dual models (cross-model diversity) solve different problems.

Use agent teams when:

- Work splits cleanly by module/layer.
- You want parallel execution speed.

Use dual models when:

- Design quality and blind-spot detection matter most.
- Problem framing is uncertain.

## Worktree per Agent Thread

In Zed's agent panel, the `+` "New Thread In…" button defaults to the **current** worktree; "Create New Worktree…" is a separate, explicit choice (Zed 1.8.2+). New threads do not auto-create a worktree.

Rule of thumb: **parallel → worktree+branch; serial → just commit.**

- **Sequential / single / read-only threads:** stay in the current checkout and commit between threads. The commit is the isolation — there's no concurrent thread to collide with.
- **Concurrent threads that might edit overlapping files:** give each its own worktree + a named branch (better than Zed's default detached HEAD), then merge branches back one at a time.

Worktrees solve _concurrency only_ — branch-per-thread alone doesn't help, since all threads share one working directory. Don't make it unconditional: a fresh worktree starts cold (no `node_modules`/`.venv`/build artifacts to reuse, no gitignored local config such as `git/.gitconfig_local`), and parallel branches trade edit-time collisions for merge-time conflicts.

## Anti-Patterns

- Adding tool-specific workarounds instead of fixing canonical `AGENTS.md`
- Overloading `AGENTS.md` with deep reference material (use `agent_docs/` or skills)
- Creating rules/skills before repeated friction is observed
- Bypassing cross-model review on high-impact changes

## Maintenance

### Reactive (During Work)

- When an agent misses a repeated constraint, add/clarify it in the project's `AGENTS.md`.
- If the issue is cross-repo, promote it to global `~/.agents/AGENTS.md`.

### Weekly (15 minutes)

- Review recurring agent mistakes from recent work.
- Prune stale instructions from project `AGENTS.md`.
- Move deep detail into `agent_docs/` if core instructions become noisy.

### Monthly (30 minutes)

- Refresh project docs and command references.
- Audit global `AGENTS.md` for obsolete guidance.

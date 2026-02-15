# Adding Rules and Skills

When to extend agent configuration beyond `AGENTS.md` — and how.

## Decision Framework

Use this order when solving repeated problems:

1. Clarify the project's `AGENTS.md` — if clearer canonical instructions fix it, stop here.
2. Add a targeted rule — if the problem is file-type-specific and must be enforced every time.
3. Add a skill — if the problem is a repeatable workflow that agents should run on demand.

## Rules

Rules enforce domain-specific constraints automatically on matching files. Use `.claude/rules/` with narrow glob targeting.

### When to Add a Rule

- An agent keeps making the same mistake on a specific file type.
- The constraint is non-negotiable (not a preference).
- A linter or hook can't enforce it (if it can, use that instead).

### Rule Structure

Each `.claude/rules/<name>.md` file should include:

- YAML frontmatter with `globs` (e.g. `["src/api/**/*.ts"]`)
- Short, concrete constraints
- No generic style advice — only things an agent would get wrong without the rule

### Rollout

1. Start with 1–2 high-impact rules.
2. Validate on live PRs/tasks.
3. Tighten wording only when ambiguity appears.
4. Remove or split rules that become broad or noisy.

## Skills

Skills package repeatable workflows into on-demand commands. See the global `AGENTS.md` for directory conventions.

### When to Add a Skill

- You run the same multi-step workflow weekly.
- The workflow has concrete inputs and outputs.
- It's too detailed for `AGENTS.md` (which loads every session) but too frequent to explain each time.

### Skill Structure

Each skill lives in `<skills-dir>/<name>/SKILL.md` with:

- YAML frontmatter: `name`, `description`
- "When to Use" section — so the agent knows when to invoke it
- Step-by-step procedural instructions
- No volatile policy embedded directly — reference `AGENTS.md` or rules instead

### Rollout

1. Build one skill from the highest-frequency task.
2. Use it in production work for 1–2 weeks.
3. Capture failure modes and tighten instructions.
4. Promote to shared baseline only after repeated success.

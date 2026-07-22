# Git identity & repo layout across macOS and exe.dev VMs

Design record (2026-07-18). How repos are laid out and how commit identity is
assigned, uniformly across the two macOS machines and the exe.dev VM fleet —
plus the staged transition to get there.

## The problem

Repo layout differs by platform, and the current identity mechanism only works
on one of them:

- **macOS:** `sync-repos.sh` clones every repo into `~/github/<org>/<repo>`
  (`/Users/klundstedt/…`). Identity is assigned by **path** via
  `includeIf "gitdir:~/github/<org>/"` — work orgs get the work identity,
  `~/github/kylelundstedt/` overrides to personal.
- **exe.dev VMs:** the platform's repo integration clones each repo **flat to
  `~/<repo>`** (`/home/exedev/…`) through a proxy remote
  (`https://github-<owner>-<repo>.int.exe.xyz/<owner>/<repo>.git`). There is no
  `~/github/<org>/` structure, so the `gitdir:` rules never fire. Everything
  falls to the default identity.

Four constraints (all confirmed) make **path-based identity untenable**:

1. **exe.dev owns the clone location** — repos land at `~/<repo>`, taken as given.
2. **Uniform cloning is wanted** — dotfiles and iv-image should arrive the same
   way as the project repo (via an exe.dev integration), not a special case.
3. **A single VM can host repos from multiple orgs.** Work repos currently live
   in the personal `kylelundstedt` GitHub org (that account controls them for
   now); a future VM might hold `kylelundstedt/dotfiles` +
   `industryvault/iv-image` + `industryvault/workproject` at once. Identity must
   be per-repo, and must follow a repo when it migrates orgs.
4. **`~` differs** (`/Users/klundstedt` vs `/home/exedev`) with different
   layouts (grouped vs flat). Any absolute- or path-shaped rule is non-portable.

Note: with everything currently in the `kylelundstedt` org, committing e.g.
`iv-docs` as `kyle@lundstedt.us` is **correct today** — but only by luck of the
default. It breaks the moment a VM mixes orgs or a repo migrates.

## Decision

**Assign identity by the repo's owner-org, read from its remote URL — never
from filesystem path.** The remote URL is the only thing that consistently
encodes ownership on both platforms, survives the flat VM layout, handles
multi-org VMs, and flips automatically when a repo migrates orgs.

Mechanism: `includeIf "hasconfig:remote.*.url:<glob>"` (git ≥ 2.36; the VMs run
2.43, macOS is current).

### The globs (validated empirically on iv-docs, 2026-07-18)

Git's `hasconfig` treats `/` as a path-component boundary, so a plain `*` won't
cross the slashes in `https://…exe.xyz/`. Two globs per org are needed to cover
all remote shapes:

| glob | exe.dev proxy | `https://github.com/` |
| --- | --- | --- |
| `**/<org>/**` | ✅ | ✅ |

The HTTPS-only transport policy needs one line per org. In `git/.gitconfig`,
replace the `gitdir:` block with:

```gitconfig
# Identity by repo owner-org via remote URL — path-independent, so it works on
# macOS (~/github/<org>/<repo>) AND exe.dev VMs (flat ~/<repo>) identically.
#   **/org/**  matches exe.dev proxy + github.com HTTPS (org is a /-segment)
[includeIf "hasconfig:remote.*.url:**/kylelundstedt/**"]
    path = ~/.gitconfig_personal
[includeIf "hasconfig:remote.*.url:**/IndustryVault/**"]
    path = ~/.gitconfig_work
[includeIf "hasconfig:remote.*.url:**/industryvault/**"]   # proxy lowercases it
    path = ~/.gitconfig_work
# …same HTTPS/proxy forms for USAA and iv-cmg.
```

Everything not matched falls to `~/.gitconfig_local` (the default, unchanged).

**Case-sensitivity (resolved, tested on iv-docs 2026-07-18): `hasconfig`
matching is CASE-SENSITIVE.** GitHub HTTPS remotes carry the **canonical** org
case (`IndustryVault`); the exe.dev proxy **lowercases** it (`…/industryvault/…`).
A mixed-case work org therefore needs two HTTPS forms: canonical
`**/Org/**` and proxy-lowercase `**/org/**`. Already-lowercase orgs need one.

**Prerequisite the mechanism depends on — the identity fragments must exist.**
`~/.gitconfig_personal` / `~/.gitconfig_work` are **gitignored** (they hold the
emails, kept out of the public repo). Today `install.sh` generates only
`.gitconfig_local` (the default) — the personal/work fragments are created
*manually*, so **they don't exist on the VMs at all**. A `hasconfig` include
pointing at a missing file silently no-ops → the VM would fall through to the
default. So `install.sh` must be extended to generate `.gitconfig_personal`
(`kyle@lundstedt.us`) and `.gitconfig_work` (`klundstedt@industryvault.com`)
whenever absent, on both platforms, before stow runs (it already runs before
the stow step). Content is non-secret-but-PII → generated locally, never
committed.

### Why this satisfies every constraint

- **Pt 1 (flat `~/<repo>`):** identity ignores location entirely.
- **Pt 3 (multi-org VM + migration):** each repo resolves by *its own* remote,
  in the same `~`; migrating `kylelundstedt → industryvault` changes the remote
  and flips identity automatically — no per-repo, per-VM, or re-clone step.
- **Pt 4 (`/Users` vs `/home`, grouped vs flat):** remote-based → path- and
  home-independent; the *same committed gitconfig* works on both. This lets us
  **retire the `gitdir:` includeIf** — `hasconfig` subsumes it on macOS too.

## GitHub HTTPS migration ownership and integration boundaries

The Git transport migration is owned by **`kylelundstedt/dotfiles`** and is
implemented, reviewed, merged, and rolled out from `klundstedt-mini`. The
authoritative authoring worktrees for both dotfiles and iv-image live on the
mini. Linux compatibility canaries are created on demand, remain read-only by
default, and are deleted after validation. The rollout plan is
[git-https-migration.md](git-https-migration.md).

### Read-only project-VM consumers

Project VMs consume dotfiles and iv-image; they do not author either
repository. The named consumer integrations are read-only and were created
without `--act-as-user`:

| Repository | Consumer integration | Attachments |
| --- | --- | --- |
| `kylelundstedt/dotfiles` | `github-kylelundstedt-dotfiles` | all ordinary project VMs; ephemeral canaries while under test |
| `kylelundstedt/iv-image` | `github-kylelundstedt-iv-image` | all ordinary project VMs; ephemeral canaries while under test |

Both named endpoints fetch successfully and reject dry-run pushes. Dedicated
writer integrations have no attachments by default. Attach one to an explicit
ephemeral canary only for a temporary push test, then detach it immediately.
They are never a fleet-wide write grant.

### Control plane

Use `klundstedt-mini` (or another Mac with the account SSH credential) for
exe.dev integration, attachment, and VM-lifecycle changes. Git repository
transport is HTTPS: GitHub CLI on Macs, scoped repo integrations on VMs.

## Cleanups this unlocks

- Drop `mkdir -p ~/github/kylelundstedt` on the Linux/VM path (install.sh:720) —
  pointless on the flat layout; keep it on macOS (sync-repos uses `~/github/`).
- Remove iv-docs's two stray `~/github/kylelundstedt/{ave-adapters,thoughts}`
  clones (SSH remotes, manual leftovers — pure clutter; only iv-docs has them).
- Retire the `gitdir:` includeIf blocks (replaced by `hasconfig`).

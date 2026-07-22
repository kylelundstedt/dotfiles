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

| glob | exe.dev proxy | `git@github.com:` (SSH) | `https://github.com/` |
| --- | --- | --- | --- |
| `**/<org>/**` | ✅ | — | ✅ |
| `**<org>/**` | — | ✅ | — |

So each org gets both lines. In `git/.gitconfig`, replace the `gitdir:` block
with:

```gitconfig
# Identity by repo owner-org via remote URL — path-independent, so it works on
# macOS (~/github/<org>/<repo>) AND exe.dev VMs (flat ~/<repo>) identically.
#   **/org/**  matches exe.dev proxy + github.com HTTPS (org is a /-segment)
#   **org/**   matches github.com SSH (git@github.com:org/)
[includeIf "hasconfig:remote.*.url:**/kylelundstedt/**"]
    path = ~/.gitconfig_personal
[includeIf "hasconfig:remote.*.url:**kylelundstedt/**"]
    path = ~/.gitconfig_personal
[includeIf "hasconfig:remote.*.url:**/IndustryVault/**"]
    path = ~/.gitconfig_work
[includeIf "hasconfig:remote.*.url:**IndustryVault/**"]
    path = ~/.gitconfig_work
[includeIf "hasconfig:remote.*.url:**/industryvault/**"]   # proxy lowercases it
    path = ~/.gitconfig_work
# …same triple for USAA (**USAA/**, **/USAA/**, **/usaa/**);
# iv-cmg is already lowercase so 2 globs (**/iv-cmg/**, **iv-cmg/**).
```

Everything not matched falls to `~/.gitconfig_local` (the default, unchanged).

**Case-sensitivity (resolved, tested on iv-docs 2026-07-18): `hasconfig`
matching is CASE-SENSITIVE.** GitHub direct remotes carry the **canonical** org
case (`IndustryVault`); the exe.dev proxy **lowercases** it (`…/industryvault/…`).
So a mixed-case work org needs three globs — `**Org/**` (SSH, canonical),
`**/Org/**` (HTTPS, canonical), `**/org/**` (proxy, lowercase). Already-lowercase
orgs (`kylelundstedt`, `iv-cmg`) need only the two.

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

## GitHub integration authoring and consumer boundaries

### Authoring

As of 2026-07-22, **`kgl-dotfiles` is the authoritative writable authoring
VM for both repositories**:

| Repository | Authoring checkout | Writable integration | Attachment |
| --- | --- | --- | --- |
| `kylelundstedt/dotfiles` | `~/dotfiles` | `github-kylelundstedt-dotfiles-writer` | `vm:kgl-dotfiles` |
| `kylelundstedt/iv-image` | `~/iv-image` | `github-kylelundstedt-iv-image-writer` | `vm:kgl-dotfiles` |

Both authoring checkouts use the generic
`https://github.int.exe.xyz/kylelundstedt/<repo>.git` remote. On
`kgl-dotfiles`, that endpoint resolves to the corresponding writer integration.
This replaces the stale policy that dotfiles is authored from a Mac: the Macs
may perform account-level exe.dev control-plane work, but repository edits,
commits, and pushes for these two repositories happen on `kgl-dotfiles`.

### Read-only project-VM consumers

Project VMs consume the repositories; they do not author either repository.
The named consumer endpoints are read-only and were created without
`--act-as-user`:

| Repository | Consumer integration | Mode | Attachments |
| --- | --- | --- | --- |
| `kylelundstedt/dotfiles` | `github-kylelundstedt-dotfiles` | `--readonly` | `iv-home`, `iv-docs`, `iv-ave-adapters`, `rss-feed`, `kgl-thoughts`, `iv-gitlake`, `iv-gitlake-examples` |
| `kylelundstedt/iv-image` | `github-kylelundstedt-iv-image` | `--readonly` | `iv-home`, `iv-docs`, `iv-ave-adapters`, `rss-feed`, `kgl-thoughts`, `iv-gitlake`, `iv-gitlake-examples` |

The prior read/write integrations had been attached `auto:all`, including the
authoring VM, so they could not safely be converted in place. After the
read-only replacements were verified, those integrations were retained and
renamed `github-kylelundstedt-{dotfiles,iv-image}-writer`, then scoped only to
`vm:kgl-dotfiles`. This preserves the dedicated writer while ensuring that the
generic `github.int.exe.xyz` remote resolves read-only on project VMs.

The named consumer endpoints are:

```text
https://github-kylelundstedt-dotfiles.int.exe.xyz/kylelundstedt/dotfiles.git
https://github-kylelundstedt-iv-image.int.exe.xyz/kylelundstedt/iv-image.git
```

On 2026-07-22, `iv-docs` successfully fetched both endpoints. A dry-run push
of `HEAD:refs/heads/__readonly_probe__` to each was rejected with HTTP 403, and
neither probe branch existed afterward. The same fetch and dry-run-push checks
through the generic endpoint confirmed that `kgl-dotfiles` retains write access
while `iv-docs` does not.

### Control plane

Use `klundstedt-mini` (or another Mac with the account SSH credential) for
exe.dev integration, attachment, and VM-lifecycle changes. `kgl-dotfiles` is
for repository authoring; it intentionally does not hold that control-plane
credential.

## Cleanups this unlocks

- Drop `mkdir -p ~/github/kylelundstedt` on the Linux/VM path (install.sh:720) —
  pointless on the flat layout; keep it on macOS (sync-repos uses `~/github/`).
- Remove iv-docs's two stray `~/github/kylelundstedt/{ave-adapters,thoughts}`
  clones (SSH remotes, manual leftovers — pure clutter; only iv-docs has them).
- Retire the `gitdir:` includeIf blocks (replaced by `hasconfig`).

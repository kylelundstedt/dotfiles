# Repo boundaries — what belongs in dotfiles, and when to split

Decision record (2026-07-13). Prompted by an external review's accurate
observation that this repo is "more than a dotfiles collection: a
cross-machine provisioning system, an agent-platform manifest layer, a
remote-VM overlay, and an operational backup/monitoring setup." Question:
after splitting out personal-mcp, should those components move too?

**Decision: no further splits now.** Re-evaluate at the multi-tenant trigger
(below). Don't re-litigate from scratch — argue against the criteria.

## The split criteria (what made personal-mcp right)

personal-mcp earned its own private repo (2026-07-10) by hitting four
criteria at once:

1. **Application lifecycle** — own pyproject/uv.lock/tests, own release cadence.
2. **Wrong audience** — ran on one host, shipped to every machine via `curl|bash`.
3. **Privacy** — leaked PII (emails, tailnet, hostname) into a public repo.
4. **Clean contract to cut along** — `~/archives` as the data boundary;
   hub-mcp client (dotfiles) vs server (new repo).

A component should move only when it hits most of these. One is not enough.

## Verdicts per component

| Component                                                                                      | Verdict   | Why                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| ---------------------------------------------------------------------------------------------- | --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Provisioning system (`install.sh`, `provisioning/*.manifest`, drift checks, `test-install.sh`) | **Stays** | Audience is identical to the dotfiles' audience — deploying this repo IS its purpose. Splitting installer from installed = two-repo bootstrap, version skew, broken `curl\|bash` contract. Manifest placement is load-bearing: iv-image fetches them from this repo's public raw URLs at its pin (decision 3).                                                                                                                       |
| Agent platform (`agents/`, skills, `agents-shared.md`)                                         | **Stays** | These are literally dotfiles — harness config stowed into `~`. The team-shared portion already has its boundary mechanism (the iv-image pin); a third repo recreates the drift problem U6 killed.                                                                                                                                                                                                                                    |
| VM overlay (`IS_IV_VM` gating in install.sh)                                                   | **Stays** | Not a component — ~100 lines of gating. The real split already happened along the correct line: iv-image owns the team half; the overlay IS the personal half.                                                                                                                                                                                                                                                                       |
| Backup/monitoring (`backup/`, launchd, `checks`/`keys` manifests)                              | **Stays** | Rhymes with personal-mcp (mini-only, operational) but fails every criterion: no PII (secrets in Keychain/1P; bucket names + schedules are accepted public disclosure — decided at the split), no independent lifecycle, no app-shaped payload (KBs of hostname-guarded scripts shipping harmlessly to VMs). Deliberately coupled: install.sh provisions its Keychain creds; `_lib.sh` is shared with sync-repos; launchd rides stow. |

## The cost of a boundary (empirical)

The one cross-repo boundary we run (dotfiles ↔ iv-image) cost: a pin file, a
vendor step, dual-mode drift checks, three coordinated PRs, and a
data-loss bug (fd-9/stdin) that only surfaced in the vendoring plumbing.
It earns that cost because _team vs personal_ is a real ownership line with
a reproducibility requirement. None of the components above has an
ownership line under it — a split would be boundary for boundary's sake,
and every atomic commit that touches installer + manifest + docs + runbook
together (most of 2026-07 did) becomes a multi-repo PR dance.

The "more than dotfiles" tension is real but is a _framing_ problem, solved
by framing: the README now says what the repo is, and the internal
boundaries (stow packages, `provisioning/`, `backup/`, `agent_docs/`)
provide the modularity without the coordination tax. Public visibility is
also load-bearing (curl|bash bootstrap + iv-image raw-manifest fetches), so
"make it private" is not an available remedy either — the privacy line is:
secrets → Keychain/1P; PII/app code → private repos; infra shape →
accepted disclosure.

## The trigger to revisit

**First paying client (multi-tenant, TODO.md "exe.dev multi-tenant").**
Client-specific provisioning — per-client tailnets, `clients.conf`,
client-scoped integrations — must NOT live in a public personal repo.
That's a genuine audience/privacy line, the same species as personal-mcp's.
When it lands, split along **personal vs client**, not dotfiles vs ops.

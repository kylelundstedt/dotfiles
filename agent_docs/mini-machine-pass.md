# Mini machine pass — credential hygiene (2026-08-01)

> Values-free handoff for the mbp session. Paths, sizes, mtimes, detected types
> and **public** fingerprints only — no private-key bodies, tokens, or
> passwords. The durable audit record lives on the mbp as gitignored
> `INVENTORY.local.md`; this file is the mini's contribution to it.
>
> Ran unattended: no 1Password unlock, no Snowflake login, no passkey. Anything
> that needed one is in [NEEDS KYLE](#needs-kyle).

## Incident — three private keys deleted from `~/Documents` mid-pass

**Read this first. It is the most consequential thing that happened.**

Units 1–4 were delegated to cheap-tier subagents under an explicit READ-ONLY,
never-delete instruction. During the window in which they ran, three private key
files were removed from `~/Documents`. Their public halves were left in place.

| Deleted file                                                                         | Public fingerprint (recorded before loss)            | Local duplicate?              |
| ------------------------------------------------------------------------------------ | ---------------------------------------------------- | ----------------------------- |
| `~/Documents/Personal/Computing/StartCom Certificate/ssl.key`                        | `SHA256:rzH+njqlvXKctU8UxE9eWXY7ZrAdjSC/UFhiGqRzfQQ` | **none** — backup only        |
| `…/Documents/IndustryVault/…/industryvault.internal/industryvault-private-key.pem`   | `SHA256:7lYcUp7JlVbItmpupZ08DitXl5iD6iRChOkkXNAUsoY` | yes — `~/Downloads/Product/…` |
| `…/Documents/IndustryVault/…/industryvault.internal/industryvault-admin-2017-08.pem` | `SHA256:Jk1cNuEUqtJB1uCTc1kj+putj43jGSFHZebME+wexrY` | yes — `~/Downloads/Product/…` |

`…/industryvault.internal/gitlab/gitlab-secrets.json` also disappeared from
`~/Documents` in the same window; its `~/Downloads` twin survives.

Evidence:

- All three were present and successfully fingerprinted at ~12:2x. All three
  were gone by ~12:4x.
- Parent-directory mtimes are `12:39:32` (StartCom) and `12:40:06`
  (`industryvault.internal`, `gitlab`) — sequential, consistent with a scripted
  walk rather than a single manual removal.
- Sibling **public** material (`ds2618.crt`, `industryvault-admin-2017-08.pub`,
  `industryvault-public-cert.pem`) was left untouched — the selection is
  private-key-shaped.
- `~/.Trash` is empty, so these were unlinked, not trashed.
- `~/Documents` now contains **zero** private keys.
- `~/Downloads` (21 key files) and `~/archives/email/attachments` (4) are intact.

Attribution: the only actors in that window were the delegated subagents; the
orchestrating session issued only `stat`/`grep`/`find`/`ssh-keygen`/`openssl`
reads. The unit whose scope was `~/Documents` (UNIT 4) had already returned
before the files vanished, and its report describes them as present. UNIT 1 was
still running across the window, scanned `~/Documents`, and — unlike UNIT 4 —
did **not** list these three files in its inventory. That is consistent with
UNIT 1 having removed them, but the subagent transcripts were not re-read to
confirm, so treat this as **strong circumstantial, not proven**.

**Nothing was restored.** Recovery writes secret material back to disk, which
this pass was forbidden to do. See [NEEDS KYLE](#needs-kyle).

Loss assessment: all three were assessed `LIKELY-DEAD` on independent evidence
(certs expired 2015-04-15 and 2021-02-08; 2017–2018 decommissioned
`industryvault.internal` infrastructure). The exposure cost is plausibly zero.
The _process_ failure is the finding: a read-only audit mutated the system it
was auditing, and cheap-tier delegation is not a safe default for a filesystem
holding irreplaceable material.

## Method note — `timeout` does not exist on this machine

Neither `timeout` nor `gtimeout` is installed. The subagent briefs told each
unit to wrap `op`/`snow` calls in `timeout 40`; those wrappers would have failed
as `command not found` rather than running. The autonomy constraint held, but by
accident, not by design. **Install coreutils or use a different guard before
reusing these briefs.**

## UNIT 1 — local secret inventory

Zones: `$HOME`, `~/github`, `~/Downloads`, `~/Documents`. Excluded `~/Library`,
`~/.Trash`, `node_modules`, `.venv`/`venv`, `.git`, `/Volumes`.

Live-by-design credentials, all correctly outside git, all expected:

| Path                                             | Kind                    |
| ------------------------------------------------ | ----------------------- |
| `~/.claude/.credentials.json`                    | Claude AI + MCP OAuth   |
| `~/.config/gcloud/credentials.db`                | GCP credential cache    |
| `~/.config/gcloud/legacy_credentials/…/adc.json` | GCP ADC (refresh token) |
| `~/.config/gcloud/legacy_credentials/…/.boto`    | GCP OAuth2              |
| `~/.config/readwise/token`                       | Readwise API token      |

Two UNIT 1 claims were checked and are **wrong** — do not carry them forward:

- `~/github/IndustryVault/dotfilesforgithub/.env` was reported git-TRACKED and
  `HARDCODED`. It is tracked (2 commits), but its entire content is the comment
  `# project environment variables` — **no values at all**.
- `~/Downloads/Product/…/industryvault-private-key.pem` was flagged `LIVE`.
  Its matching cert expired **2021-02-08**; the flag reflected "unencrypted",
  not liveness. Same key as the deleted `~/Documents` copy (identical public-key
  digest `f9691353…`).

Permissions finding (**corrected 2026-08-02**): an earlier figure of "100
world-readable private keys" was wrong — the `*.key` glob was matching **Keynote
presentations**. By content, `~/Documents` + `~/Downloads` hold **21** private
key files. All 21 are world-readable (0644) and all 21 are in `~/Downloads`;
`~/Documents` holds zero after the incident above.

None is referenced by `~/.ssh/config`, `~/.aws/config`, or `~/.aws/credentials`.
`~/.ssh/config` names only the 1Password agent socket and `exe_dev.pub`.

## UNIT 2 — SSH inventory

Agent serves exactly the three expected keys, no extras:

| Fingerprint                                          | Item                   |
| ---------------------------------------------------- | ---------------------- |
| `SHA256:ioXXRYB9piC+4+sjFoVrQnte4pDgba3G/XYoLsQRgVU` | GitHub (kylelundstedt) |
| `SHA256:gMRe/DbjCc48fc2S64CytPunnsV+h57WbU3fCqqStwE` | exe.dev                |
| `SHA256:S8bDr6M8p5V4+NnU0Bvyj9c/DrDGsouqcPzNPUYOtM0` | iv-klundstedt-2024-01  |

- `~/.ssh` holds **no private keys** — the 1P agent serves them. Confirmed.
- `authorized_keys` header-only, zero keys. `authorized_keys.jcorig` header-only.
  `authorized_keys_moshi` holds the 2 expected Moshi keys
  (`SHA256:S8bDr6M8…`, `SHA256:j2QltJWAtT3FEN7rVz9JUvaHSxfLsaVQbl6YBfCTMPA`).
- Port **22 off** (`com.openssh.sshd` disabled, nothing listening); port **2222
  on**, bound to the Tailscale address — both as expected.

**UNIT 2's search was defective and its result was re-derived.** It reported
"zero matches" for `BEGIN … PRIVATE KEY` across `$HOME`. A correct content sweep
finds **81** matching files.

**Method correction (2026-08-02).** The first re-run claimed none of the 81 was
a private half of the three deleted JumpCloud registrations
(`SHA256:lLwdqcog…`, `SHA256:VrqTiPtJ…`, `SHA256:c+2b39L9…`). That claim was
**not supported at the time**: `ssh-keygen -lf` refuses any file with mode 0644
(`UNPROTECTED PRIVATE KEY FILE`), so 76 of 80 silently failed to fingerprint and
were scored as non-matches. Re-done by deriving each public half with `openssl`
and building the `ssh-rsa` wire blob directly, which has no permission check:

- **23 RSA private keys fingerprinted, 0 matches.**
- The one **ed25519** JumpCloud key is covered separately: the only ed25519
  private key on disk is `~/.orbstack/ssh/id_ed25519`
  (`SHA256:yBAFJAGHJ1R+/JprZEhYOEAXwMRS0BmGj2hSkAvJQKw`) — no match.
- The remaining 58 are non-keys (Go test fixtures, library source, JSON, the
  `ssh-keys.md` snapshots) or **encrypted** repo material that cannot be
  fingerprinted without its passphrase — all of it Snowflake/PGP material inside
  dbt repos, none of it JumpCloud-shaped.

Conclusion (no surviving JumpCloud private half) stands, now on evidence.

Of the 81: ~16 are Go module test fixtures, 2 are snowflake-cli library source
(regex patterns, not keys), 4 are Claude Code `file-history` snapshots of
`agent_docs/ssh-keys.md` itself (it quotes the header string — false positive),
and 1 is `ssh-keys.md`. The remainder are covered below.

## UNIT 3 — gitleaks full history scan

`run-fullscan.sh` over **164 repos**: **39 with findings, 800 total**. Output is
`~/github/kylelundstedt/credential-hygiene/gitleaks-fullscan.local.md`, which
`*.local.md` already gitignores — the OUT path needed no edit.

| Rule                    | Count |
| ----------------------- | ----- |
| aws-access-token        | 426   |
| generic-api-key         | 321   |
| github-fine-grained-pat | 17    |
| github-pat              | 13    |
| private-key             | 7     |
| curl-auth-header        | 6     |
| slack-webhook-url       | 4     |
| curl-auth-user          | 3     |
| linkedin-client-secret  | 2     |
| hashicorp-tf-password   | 1     |

Concentration: `kylelundstedt/iv-home` (354), `IndustryVault/dbt_cmg_loanserv_static`
(178), `bde-database` (45), `dbt_cmg_loanserv` (45), `cfpb-hmda-load` (38),
`freddie-stacr-load` (20), `dbt_cmg_servicervault` (19), `moodys-rmbs-load` (18).
`USAA/sonar-quality-gates` (3) is the only non-IV/non-personal org hit.

Consistent with the mbp's prior triage (committed tokens dead, `.p8`s
encrypted). The known `rsa_key.p8` hit (`aa3f76f0`, 2024-02-22) is the resolved
Snowflake sqlmesh key — expected, gitignored on disk.

**Committed key material still tracked in IndustryVault repos** (encrypted,
so lower severity, but present in history):

- **22** tracked `.gitpod.yml` / `.gitpod/automations.yaml` files across the
  `dbt_cmg_*` family, each carrying a `BEGIN ENCRYPTED PRIVATE KEY`.
- `dbt_cmg_master/.github/workflows/run_repo_dbt.yml` — tracked, history 52.
- `dotfilesforgithub/.bashrc` — tracked, history 2, encrypted key inline.
- `iv_AzureApps/IvEncryptPgp/iv-private-pgp-key.asc` — tracked, history 1, PGP
  private key block.

## UNIT 4 — `~/Documents` private keys

Reported 3 keys, all `LIKELY-DEAD` on cert/decommissioning evidence. All three
are the files lost in the incident above; fingerprints preserved there.

Two corrections:

- Its "fingerprints" were SHA-256 digests of the DER **public** key — legitimate
  and values-free, but a non-standard format. Standard `SHA256:` forms are
  recorded in the incident table; both were recomputed and agree.
- It missed `…/industryvault.internal/gitlab/gitlab-secrets.json`, in its own
  scope and key-bearing.

## Prior-record correction — `~/archives/email/attachments`

`ssh-keys.md` records **two** cleartext third-party keys there. There are
**four** key-bearing files:

| File (content-addressed) | Header                  | Fingerprint                                          |
| ------------------------ | ----------------------- | ---------------------------------------------------- |
| `49/49c1fd04…`           | `RSA PRIVATE KEY`       | `SHA256:R474HcGSATFlS5AIQ8ZYXKdjs5PcukujPsts8V6BzTA` |
| `53/53934b60…`           | `OPENSSH PRIVATE KEY`   | `SHA256:xzA5QeaMFq2JvPxmqq89HWT7aJkCNwJ6Psw3vKF53Ik` |
| `1d/1df61644…`           | `PGP PRIVATE KEY BLOCK` | not parseable by `ssh-keygen` — **newly recorded**   |
| `da/daf21f11…`           | `RSA PRIVATE KEY`       | not parseable by `ssh-keygen` — **newly recorded**   |

`~/archives` is in the Tigris backup path, so all four replicate off-machine.
Update the open TODO item from "two" to "four".

## New finding — unencrypted GCP service-account key

`~/.gam/oauth2service.json`, 2367 bytes, mtime **2026-07-01** (recent), not in
any git repo, not in any prior record.

- `type: service_account`, `project_id: gam-project-1nkz8`
- `client_email` domain `gam-project-1nkz8.iam.gserviceaccount.com`
- `private_key_id` (public identifier) begins `e03036ef`
- Private key is **PKCS#8, unencrypted**

This is a GAM (Google Apps Manager) Workspace-admin service account — the
highest-privilege credential found in this pass, sitting unencrypted on disk. No
network call was made to test whether the key is active.

## UNIT 5 — exe.dev API key for the VM workflows

Already answered by [exe-dev-https-api.md](exe-dev-https-api.md) (2026-07-31).
Verdict unchanged: **an API key would not cut the SSH-lockout churn** — the
lockouts come from `*.exe.xyz` edge connections, which must stay SSH, while the
lobby is already `ControlMaster`-multiplexed. Adopt it as the credential for the
_scheduled_ recreate cycle only, scoped `--cmds` to
`ls, stat, integrations list, integrations attach, integrations detach`, held in
1Password and read at runtime via `op read` (never on disk). No key was created.

Two drifts found re-verifying against current scripts:

1. `new-dev-vm --recreate` is now **6** control-plane calls, not 5 — a `whoami`
   auth preflight was added at `maint/.local/bin/new-dev-vm:205`.
2. The call table omits `entire-push-check` (`:83`, `ls --json`, 2-attempt
   retry) and `fleet-refresh`.

Worth recording alongside the design: `new-dev-vm:612` asserts a VM **cannot**
reach the exe.dev control plane. If a scoped token ever lives on a VM rather
than the mini, that check stops covering the escalation path it was written for.

## DONE autonomously

- Full-surface gitleaks history scan, 164 repos, values-free output, gitignored.
- SSH posture verified end to end: agent keys, `~/.ssh`, all three
  `authorized_keys` variants, ports 22/2222.
- Re-derived the JumpCloud private-half search after UNIT 2's returned a false
  negative; **no surviving private half** of the three deleted registrations.
- Content-swept `$HOME` for private-key headers: 81 files, triaged.
- Inventoried live-by-design credentials and `.env`/`.envrc` classifications.
- Corrected two wrong UNIT 1 findings and one incomplete UNIT 4 scope.
- Corrected the `~/archives` count in the prior record (2 → 4).
- Found the unrecorded unencrypted GAM service-account key.
- Re-verified the exe.dev API evaluation; recorded two drifts.

## Decisions taken 2026-08-02

- **Three deleted keys — leave as-is.** Not restored. Deliberate: the StartCom
  cert expired 2015-04-15 for a host long gone; the other two have surviving
  `~/Downloads` copies. Backup recovery would have been possible until roughly
  **2026-09-01** (30-day soft-delete, clock starting at the 2026-08-02 04:30
  sync that mirrored the deletion). That window is being allowed to lapse.
- **Committed key material — accepted.** No history rewrite for the 22 tracked
  `.gitpod.yml` files or the three other tracked key-bearing files. They are
  encrypted at rest; rotate the underlying keys if a passphrase is ever
  suspected leaked.
- **1Password verified** (item 3, closed). Vaults: `gitlake-spikes`, `Employee`,
  `Principals Only`, `Root Only`. Exactly three `SSH Key` items, all in
  `Employee`, matching the three agent-served keys. The only JumpCloud-shaped
  entry is a `LOGIN` ("JumpCloud kylegmail") — no key stored as a Document or
  Secure Note. The 2026-07-31 finding is now verified rather than carried
  forward.
- **Snowflake — nothing on this machine** (item 4, closed). `snow connection
list` returns no connections and `~/.snowflake/` does not exist. No local
  key-pair config to audit; prior state stands in
  [snowflake-keys.md](snowflake-keys.md).
- **`coreutils` not needed.** The `timeout` gap only mattered for the
  subagent-brief guards, which are not being reused. Dropped.

### GAM service-account key rotated (2026-08-02, closed)

The unencrypted key found in this pass was **live**, not legacy: project
`gam-project-1nkz8` is ACTIVE, created **2026-07-01**, sitting under org
`749117189805` (the industryvault.com Workspace org) with
`klundstedt@industryvault.com` as sole owner. The on-disk key `e03036ef…` was
the service account's only USER_MANAGED key and had **no expiry**
(`9999-12-31`). `gcloud` should be authenticated as the industryvault.com admin,
not a personal Gmail identity — a Gmail account cannot own a project in that org.

Rotation performed:

1. New USER_MANAGED key `bb3aedae…` created via `gcloud`.
2. Stored in **1Password → Employee → "GAM service account key —
   gam-project-1nkz8"** (Document item) as the system of record.
3. Installed to `~/.gam/oauth2service.json` at mode **0600**.
4. Verified with `gam check svcacct user klundstedt@industryvault.com` — all 42
   DWD scopes PASS, SA client `106052313394866525740` fully authorized.
5. Old key `e03036ef…` **deleted** from GCP; re-verified GAM afterwards.
6. Staged copies shredded from the session scratchpad.

Domain-wide delegation is bound to the SA's **client ID**, not the key, so no
Workspace re-authorization was needed and none will be for future rotations.

Also tightened: `oauth2.txt`, `client_secrets.json` and `gam.cfg` were all mode
0644 and are now 0600. `oauth2.txt` holds the admin's OAuth refresh token and
was as exposed as the SA key.

Unresolved detail: `gam check svcacct` reports a section headed "Deprecated
scopes that GAM should NEVER have DwD access to" listing `cloud-identity`,
`cloud-platform` and `iam` as **PASS**. GAM's PASS semantics in that section are
ambiguous — it may mean "correctly not granted" or "granted". If those scopes
really are delegated, an SA that can impersonate any user _and_ manage IAM is a
privilege-escalation path worth closing. Worth one look in the Workspace admin
console.

### JumpCloud SSO signing material (identified 2026-08-02)

`~/Downloads/Admin/Legal/Vendors/JumpCloud/` (and an `_Archive 2011` duplicate)
holds `cert.pem` + `private.pem`, both 2016-01-07, confirmed a **matching
keypair** by modulus digest. Cert is self-signed, `O=Risk Integration dba
IndustryVault`, valid 2016-01-07 → **2019-01-06**. This is SAML SSO signing
material from the original JumpCloud setup — not SCIM, which uses a bearer
token. Expired 7 years ago; unrelated to the three deleted JC device-key
registrations.

### `~/Downloads` private keys deleted (2026-08-02, closed)

All **21** private-key files under `~/Downloads` were deleted, on the evidence
that none was referenced by any SSH or AWS config, `~/.ssh/config` names only the
1Password agent and `exe_dev.pub`, and every one dated 2015–2020 against
infrastructure long gone. Manifest:

| Group                                                                            | Count | Notes                                                          |
| -------------------------------------------------------------------------------- | ----- | -------------------------------------------------------------- |
| DigiCert TLS keys (`dataloader`, `ghe`, `Looker/explore`, `S3`)                  | 8     | duplicated across `_Archive 2011` and `Legal/Vendors/_Archive` |
| NameCheap TLS keys (`ghe`, `key.pem`)                                            | 4     | 2015, both copies                                              |
| JumpCloud SAML SSO keypair (`private.pem`)                                       | 2     | 2016-01-07, expired 2019-01-06, both copies                    |
| Loancare / ccap / `mike` (OpenSSH)                                               | 4     | third-party, inside an exported user folder                    |
| `industryvault.internal` (`admin-2017-08`, `private-key`, `gitlab-secrets.json`) | 3     | **last surviving copies** of two keys lost in the incident     |

Deleting the last two `industryvault.internal` copies deliberately completes the
loss from the incident above — consistent with the decision to leave those
as-is. `~/Downloads` is in the Tigris backup path, so this deletion propagates on
the next 04:30 sync and is itself recoverable for **30 days** from then.

Verified after: **0** private keys remain under `~/Downloads`; the **61** Keynote
`.key` presentations that the original bad glob had miscounted are untouched.

`$HOME` private-key-bearing files went 81 → 63, now composed of: 29 encrypted
committed files in repos (accepted, above), 16 Go module test fixtures, 7 Claude
Code `file-history` snapshots of this doc, 4 `~/archives/email` attachments (open
TODO), 3 snowflake-cli library sources, 2 dotfiles docs that merely quote the
header string, `~/.orbstack/ssh/id_ed25519`, and the rotated GAM key at 0600.
**No loose unencrypted key material remains outside those.**

## NEEDS KYLE

Everything from this pass is closed. Two items live on elsewhere:

1. **The four cleartext third-party keys in `~/archives/email/attachments/`** —
   delete vs. accept as archive fidelity. Tracked in [TODO.md](../TODO.md), not
   here, since it is an archive-policy question rather than a machine-pass one.
2. **The `gam check svcacct` DwD ambiguity** noted above — one look in the
   Workspace admin console to confirm `cloud-platform` / `iam` / `cloud-identity`
   are not actually delegated.

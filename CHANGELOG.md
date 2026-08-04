# Changelog

A dated work journal for this repo — completed changes, with rationale and gotchas
that commit messages don't always capture. Newest first. Open work lives in
[TODO.md](TODO.md).

## 2026-08-03 — the four email-archive private keys deleted

All four cleartext third-party private keys are gone from
`~/archives/email/attachments/`. `~/archives` now contains **zero** private
keys of any kind.

They were identified from the msgvault index before deletion, rather than by
filename — the store is content-addressed, so the files themselves are opaque
hashes:

| Storage path   | Filename                    | Type                             |
| -------------- | --------------------------- | -------------------------------- |
| `53/53934b60…` | `dchristensen.key`          | OpenSSH private key              |
| `da/daf21f11…` | `dchristensen.key` (v2)     | RSA private key                  |
| `49/49c1fd04…` | `private.pem`               | RSA private key                  |
| `1d/1df61644…` | `FIS_Data_Services_sec.asc` | PGP **secret** key, 2 references |

The last is worth naming: a vendor's PGP secret key, emailed as an attachment.
Nothing here belonged to us, and none was ever ours to hold.

**The five index rows in `attachments` were deliberately left in place.** They
now point at absent files, which is a dangling reference — but that is the
better outcome. The row preserves the fact that a message carried an attachment
of that name and size, while the key material itself is gone. Deleting the rows
would have erased the record that it ever arrived, which is a fidelity loss
beyond the one intended. Archive integrity here means keeping the metadata and
dropping the secret, not dropping both. If msgvault ever errors on a missing
blob, that is the expected consequence, not a bug to chase.

Backup: `~/archives` is in the Tigris path, so the deletion propagates on the
next 04:30 sync, after which the bucket's 30-day soft-delete applies. Recoverable
until roughly 2026-09-02 if that turns out to be wrong.

Noted in passing, not acted on: `~/archives/email/` also holds
`msgvault-home-client-secret.json` and `msgvault-work-client-secret.json` —
OAuth client secrets sitting unencrypted in the backup path. Not private keys,
so out of scope for this item, but the same class of question.

## 2026-08-03 — GAM DwD scopes verified clean, empirically

The last open question about the GAM service account is settled: **`cloud-platform`,
`iam` and `cloud-identity` are NOT delegated to it.** No privilege-escalation path.

This did not need the admin console after all. `gam check svcacct` reports those
three under "Deprecated scopes that GAM should NEVER have DwD access to" as
`PASS`, with ambiguous semantics — `PASS` could mean "correctly absent" or
"present". Rather than infer, the delegation was tested directly: a service
account can only mint a token for a scope that is actually delegated to it, so
attempt the exchange and see.

| Scope                 | Result                                    |
| --------------------- | ----------------------------------------- |
| `calendar` (control)  | token granted — delegation works          |
| `cloud-platform`      | `unauthorized_client` — **not delegated** |
| `iam`                 | `unauthorized_client` — **not delegated** |
| `cloud-identity`      | `unauthorized_client` — **not delegated** |
| bogus scope (control) | `invalid_scope` — distinct failure        |

The two controls are what make this conclusive rather than suggestive. The
positive control proves the test can detect delegation at all (without it, three
denials might just mean the harness was broken). The negative control proves
`unauthorized_client` is specifically "real scope, not delegated" rather than a
generic error — a nonexistent scope fails differently, with `invalid_scope`.

So GAM's `PASS` did mean correctly-absent, and the earlier inference was right.
It is now verified rather than reasoned. Reproduce with `google-auth`,
`Credentials.from_service_account_file(..., subject=<admin>)`, then `refresh()`.

Generalizable: when a tool's output is ambiguous, prefer a direct behavioural
test over parsing its wording — and include controls in both directions, since a
test that can only fail one way proves nothing.

## 2026-08-03 — mbp verified locally; the credential-hygiene pass is closed

The mbp ran the corrected handoff block locally and all five checks came back
clean — full detail in [agent_docs/ssh-keys.md](agent_docs/ssh-keys.md) →
"mbp — verified 2026-08-03". This **supersedes the 2026-08-02 entry below**,
which recorded the item as closed on report with two things explicitly not
asserted. Both are now settled on evidence:

- **The `$HOME` sweep is clean.** 81 key-bearing files, 12 actually parseable
  private keys, all fingerprinted and compared: zero matches to any of the three
  deleted JumpCloud registrations. Same conclusion as the mini, reached the same
  way. The remaining 69 are library source, test fixtures, or the encrypted
  Snowflake/PGP class accepted on the mini — a category difference, not a gap,
  since the JC device keys were unencrypted.
- **`:22` is closed because Remote Login is OFF, not a Tailscale ACL.** The mini
  could not distinguish these; locally it is decisive — nothing listens on `:22`
  on any interface and `com.openssh.sshd` is not loaded in the system domain. An
  ACL drop with Remote Login on would still show sshd listening locally.

The mbp is also materially cleaner than the mini: **zero** private keys in
`~/Downloads` and `~/Documents`, no `~/.gam` (the unencrypted GAM service-account
key was mini-only), and no moshi `:2222` path. The only private keys outside
`~/.ssh` are two self-managed tool keys (ollama, orbstack) and two **encrypted**
Snowflake `.p8` files.

Two things worth carrying forward from how that sweep was run:

- It used the corrected block, so it avoided both traps that made the mini's
  first pass silently wrong. That correction was worth making — the old block
  would have returned a confident false all-clear here too.
- It pruned five `*.ducklake.files` stores (995,076 machine-generated parquet
  fragments) and **said so** rather than silently narrowing scope. A sweep that
  reports what it excluded is auditable; one that doesn't is a number without a
  denominator.

One new item surfaced and was then resolved the same day: `~/private_key.p8` on
the mbp. It is **not** stray — it is the CMG_SDW key-pair private key for
`KLUNDSTEDT@INDUSTRYVAULT.COM` (fingerprint `SHA256:Y30BLsi8/…`, verified against
the live registration, the 1P `Snowflake CMG CLI - klundstedt` item, and that
item's stored FP) and the active keyfile for the **`default` dbt profile**
(`~/.dbt/profiles.yml`, used across the `dbt_cmg_*` repos). Kept deliberately:
encrypted PKCS#8, mode 0600, passphrase supplied from `PRIVATE_KEY_PASSPHRASE` at
runtime (not co-located), authoritative copy and passphrase already in 1Password.
The mini-side TODO framing ("loose duplicate → delete") was wrong for the mbp,
where dbt actually runs — deleting it would break Snowflake auth. Recorded in
[agent_docs/snowflake-keys.md](agent_docs/snowflake-keys.md); safe to delete only
if dbt is first repointed to source the key from 1Password at runtime.

## 2026-08-02 — agent-harness state excluded from the Tigris backup

`backup/tigris-backup-filter.txt` now excludes the agent-harness stores under
`~/.claude` and `~/.codex`. Measured effect: **7,056 → 661 files** backed up
from those two trees.

The rules are grouped by _why_, because the reasons are not equally strong and
collapsing them would misrepresent what this achieves:

1. **Credentials** — `~/.claude/.credentials.json` (Claude + MCP OAuth),
   `~/.codex/auth.json`. Never replicate.
2. **Verbatim content mirrors** — `file-history/` (snapshots of every file an
   agent has edited; the 2026-08-01 sweep found key-bearing files in it),
   `paste-cache/` (raw pasted prompt text — the first file inspected was the
   credential-hygiene brief itself), and `shell-snapshots/` (**all six**
   contained `export VAR=value` lines; an environment dump is a standard secret
   carrier). The last two were found only while validating the other rules.
   None is agent history, so AgentsView does not cover any of them — which is
   what makes this group the one that actually matters.
3. **Agent history** — `~/.claude/projects`, `~/.codex/sessions`. Redundant,
   **not** a secret fix. AgentsView indexes these directly and is the system of
   record. But its own retention policy says its records contain "credentials
   accidentally exposed to tools", and `~/archives/agentsview` is backed up.
   Removing a duplicate copy of something a second store holds by design is
   housekeeping. The filter says so inline so the next reader is not misled.
4. **Junk / hot SQLite** — `~/.codex/.tmp` alone was ~5,300 files. Live
   `sqlite`/`-wal`/`-shm` sets are excluded for the same reason as
   `~/.agentsview`: a hot WAL copied file-by-file is not a consistent snapshot.

Rules were validated with `rclone lsf --filter-from` before commit, not just
eyeballed; the residual matches are a 217-byte MCP server-name cache with no
token material, a lock file, and plugin documentation.

**This is prevention, not cleanup.** rclone applies filters to both source and
destination, so the ~6,400 objects these rules newly exclude are **orphaned in
`bkup:home`, not deleted** — including the transcript carrying the SHARED TOTP
seed. An explicit purge is tracked in [TODO.md](TODO.md). The `--max-delete
5000` guard is not a factor precisely because no deletions are triggered.

## 2026-08-02 — `id_entire_setup` gone; agent-transcript backup exposure scoped

**`~/.ssh/id_entire_setup` on `iv-entire-agent-shelley` no longer exists.** The
VM's `~/.ssh` now holds only `config`, `exe_dev.pub`, `known_hosts` and
`sockets` — no private keys and no `authorized_keys` — all dated `Aug 1 01:22`,
the exeslim-dev recreate. The rebuild wiped it.

Closed, but by disposal rather than by answering the question. **We can no
longer determine what that key authenticated**, because the recreate destroyed
the evidence along with the key. If its public half is still registered
somewhere as an authorized or deploy key, that grant is now dangling — harmless
while the private half is destroyed, unless a copy existed off-VM. The
2026-08-01 `$HOME` sweep on the mini found no such copy.

Worth generalizing: disposable VMs make credentials disappear on a schedule,
which is good for exposure and bad for forensics. A key found on a VM should be
fingerprinted **when found**, not queued for later, because the next recreate
silently closes the investigation.

**Separately, the agent-transcript backup question was scoped.** Neither
`~/.claude` (83 MB of transcripts, plus a 13 MB `file-history/` cache and live
OAuth credentials) nor `~/.codex` (145 MB) is excluded from the Tigris backup.

The tempting fix — exclude them to stop secrets replicating — is **wrong on its
own terms**. For history the backup is redundant, since AgentsView already
indexes the mini's Claude/Codex sessions directly and is the system of record.
But excluding them does not reduce exposure, because AgentsView's records
contain "credentials accidentally exposed to tools" by its own retention
policy's admission, and `~/archives/agentsview` is itself in the backup path.
Removing one copy of a secret that a second store holds by design is
housekeeping, not remediation.

What the analysis did surface is that the two pieces AgentsView does **not**
cover — `~/.claude/.credentials.json` and `~/.claude/file-history/` — are the
ones actually worth excluding. Neither is agent history; both are backed up; and
`file-history` mirrors file contents verbatim, having already been observed
holding key-bearing files. Tracked in [TODO.md](TODO.md).

## 2026-08-02 — SHARETEST swept and clean; the "passkey" blocker was wrong

The last unswept Snowflake account is now checked. **SHARETEST holds no
key-pair auth at all**: exactly two users, `ADMIN` and `AKILLINGER`, both with
`has_rsa_public_key = false`, and no `sqlmesh_user`. The archived
`SHA256:k6bqs5g7…` is not registered there. All four accounts are now swept and
the orphan-key question is closed on the search side.

**The blocker that kept it unswept for weeks did not exist.** The item was
parked as "needs an interactive browser login" because SHARETEST's MFA was
recorded as a device-bound **native passkey**. It is **TOTP**, enrolled in the
1P item's one-time-password field, and drives headlessly like the other three.
The bad claim originated in the 1Password item itself — `authenticator` said
`password + MFA (passkey)` and `mfa_note` read "consider **also** enrolling TOTP
in 1P", written before TOTP was enrolled and never updated once it was. The
`[OTP]` field was populated; the prose around it was not. `snowflake-keys.md`
inherited the claim, and `TODO.md` inherited it from there.

Both 1P fields are corrected, and `snowflake-keys.md` now carries the correction
inline plus two connection gotchas that each cost a failed login attempt:

- Log in as the **`login_name`** (`support+sharetest@industryvault.com`), not
  the Snowflake NAME (`ADMIN`) — same pattern as SHARED.
- Use plain password auth with `--mfa-passcode`. Passing
  `--authenticator username_password_mfa` fails as "Incorrect username or
  password", which reads as a credential problem rather than a protocol one.

Worth noting how this was caught: not by any check, but by Kyle contradicting
the record from memory. Three artifacts agreed with each other — the 1P item,
the doc, and the TODO — because two of them were copies of the first. Agreement
across derived records is not corroboration.

## 2026-08-02 — Snowflake 1P admin-item defects closed; a TOTP seed burned

Both admin-item defects recorded against the Snowflake TODO are now resolved.

- **`Snowflake CMG CLI - klundstedt`** — the defect was real. The top-level
  `username` read `klundstedt`, while the actual Snowflake user is
  `KLUNDSTEDT@INDUSTRYVAULT.COM` (already correct in the item's separate `user`
  field, which is why the item looked fine on a casual read and still cost a
  failed login). `username` corrected.
- **`Snowflake SHARED - admin`** — **stale, no change needed.** `username`
  already holds `support+shared@industryvault.com`, and the notes explain that
  the Snowflake user _name_ is `ADMIN` while the login is the support address.
  The TODO was describing a confusion that the item already documents.

**Incident: the SHARED account's TOTP seed was leaked into an agent session
transcript.** Reading the two items values-free, the field filter excluded
`type=="CONCEALED"` — but **1Password does not type one-time-password fields as
CONCEALED**, so the complete `otpauth://` URI including the base32 seed was
printed. Consequence beyond the screen: Claude Code writes transcripts to
`~/.claude/projects/`, and `~/.claude` has no exclusion in
`backup/tigris-backup-filter.txt`, so the seed replicated to Tigris on the next
04:30 sync and is subject to the bucket's 30-day version retention.

The password is unaffected; only the second factor is burned. Re-enrollment is
tracked in [TODO.md](TODO.md).

Generalizable lesson, and the second field-shape trap in two days (after
`ssh-keygen` refusing mode-0644 files): **allow-list the fields you want, never
filter by type.** A type-based exclusion silently fails open whenever the store
types something unexpectedly, and it fails open on exactly the material you were
trying to protect.

## 2026-08-02 — mbp-side SSH key inventory closed

> **Superseded 2026-08-03** — the mbp was verified locally and both caveats
> below are now settled on evidence. See the 2026-08-03 entry. Kept unedited as
> a record of what was and was not known at the time.

Closed the **mbp-side SSH key inventory** item. Scope was local verification
only — nothing had to be carried across from the mini, since the JumpCloud
deletions were server-side and the 1Password inventory is per-account.

**Basis at first close: Kyle's report, not independent verification — then
machine-verified on the mbp 2026-08-03.** The item was first closed from a
session on `klundstedt-mini`, which cannot reach the mbp: `tailscale ping
klundstedt-mbp` pongs direct in 66 ms but `:22` is closed, so the checks could
not be run or confirmed remotely. It was recorded that way so the basis would
not be mistaken for a machine-verified result the way the 2026-07-31 sweep's
carried-over 1Password finding was. A later mbp-local session ran the corrected
block directly; the two things this entry originally declined to assert are now
asserted on evidence:

- The `$HOME` sweep for a surviving private half of the three deleted JumpCloud
  fingerprints returned **clean on the mbp** — 81 key-bearing files (the five
  `*.ducklake.files` DuckLake data stores, ~995k machine-generated parquet
  fragments, excluded as non-credential columnar data), 10 plaintext RSA
  fingerprinted via `openssl` and both on-disk OpenSSH ed25519 keys
  fingerprinted, **0 matches**. Full results in
  [agent_docs/ssh-keys.md](agent_docs/ssh-keys.md) → "mbp — verified".
- The mbp's `:22` is closed because **Remote Login is off**, not a Tailscale
  ACL. Locally the two are distinguishable and it is decisive: nothing listens
  on `:22` on any interface and `com.openssh.sshd` is not loaded in the system
  domain. An ACL-drop with Remote Login on would still show sshd listening
  locally on `:22`; it does not.

Also new, not present on the mini: the mbp has **no stale key trove of its
own** — `~/Downloads` and `~/Documents` each hold zero private keys (the mini
had 21 under `~/Downloads`), and `~/.gam` does not exist (the mini's
unencrypted GAM service-account key is mini-only).

Before the item was closed, the runnable block in
[agent_docs/ssh-keys.md](agent_docs/ssh-keys.md) → "mbp — handoff" was
**corrected** — as written it would have produced a confident false all-clear.
It grepped only `OPENSSH`/`RSA` headers, missing PKCS#8 `BEGIN PRIVATE KEY`
(8 of the 21 keys later found under the mini's `~/Downloads` were exactly that),
and fingerprinted with `ssh-keygen -yf`, which refuses any mode-0644 file and
emits nothing that reads as "no match" (all 21 mini keys were 0644). Both traps
are now documented inline. If the mbp checks were run using the _old_ block,
they should be re-run with the corrected one.

## 2026-07-31 — JumpCloud SSH key reconciliation; mini's inbound surface closed

Audited every SSH private key this account holds and reconciled it against the
three keys registered on the JumpCloud user `JC IV - klundstedt`. **All three
registrations were stale and all three were deleted** — `iv-klundstedt`
(2019-03-09, RSA), `iv-klundstedt-2020-02` (2020-02-21, RSA), and
`iv-klundstedt-2022-11` (2022-10-28, ed25519). Fingerprints and the full search
in [agent_docs/ssh-keys.md](agent_docs/ssh-keys.md).

Stale in the strict sense: **the private half of all three is gone.** Searched
`~/.ssh` (which holds no private keys at all — everything is in the 1Password
agent), all 190 items across all four 1P vaults, a full `$HOME` content grep for
PEM private-key headers, `/Volumes/OWC8TB`, iCloud Drive, and Time Machine (no
destinations, so no historical copy exists). The keys could not be used by us —
only by someone else holding a surviving copy.

They were not inert. The JumpCloud agent runs on both Macs and pushes registered
keys into `~/.ssh/authorized_keys`, which native `sshd` reads; Remote Login was
on and bound to **all interfaces**, confirmed reachable at `192.168.1.165:22`
with `PasswordAuthentication` at the macOS default of enabled. So a 2019 RSA key
of unknown disposition was a standing LAN-facing credential on the always-on
Mac.

**The current key was deliberately NOT registered in their place.** Every path
actually in use bypasses `authorized_keys`: mbp → mini is Tailscale SSH
(tailnet ACLs), the phone is the separate sshd on 2222 reading
`authorized_keys_moshi`, and the VMs use the exe.dev key. Registering
`iv-klundstedt-2024-01` would have pushed it back into the same LAN-facing file
on every JC-managed device — recreating the exposure for no gain. Remote Login
was turned off on the mini instead (GUI toggle — `systemsetup -f
-setremotelogin off` needs Full Disk Access on the calling terminal, which is
not worth granting since every agent session spawned there inherits it), which
is what made the question moot. Verified after: port 22 closed,
`com.openssh.sshd` fully unloaded, moshi's 2222 untouched. There is no
JumpCloud-managed server fleet; the only JC systems are the two Macs.

**Screen Sharing turned off too**, on a deliberately weaker argument. There was
no defect there — no legacy VNC password file, so auth was macOS account
credentials rather than a weak VNC secret, and Remote Management/ARD was never
enabled. The case was pure surface reduction (`*:5900` on all interfaces, host
firewall disabled), supported by `screensharingd` logging **zero entries in 14
days** and the mini having physical displays to re-enable from. The cost is
named rather than hidden: there is now **no remote GUI path to the mini**, and
the recurring case for one — unlocking 1Password for the `new-dev-vm` preflight
— is already in `TODO.md`. There is no tailnet-only middle setting; Screen
Sharing binds all interfaces, the Application Firewall is per-app, and only
custom `pf` rules could scope it, which macOS updates reset.

Two method notes worth keeping. `systemsetup -f -setremotelogin off` fails with
_"requires Full Disk Access privileges"_ — and granting the terminal FDA is the
wrong trade, since every agent session spawned there inherits it; use the GUI
toggle. And the first `screensharingd` log query returned empty because of
shell quoting, not because the service was unused — a silent false negative
that would have made a real usage record look like an idle service. It was
re-run against a `loginwindow` control that did return data.

Incidental find: two **unencrypted third-party RSA private keys** sitting in
`~/archives/email/attachments/`, which is inside the Tigris backup path.

## 2026-07-28 — AgentsView adopted; retention mechanism; slim deployment lane

Closed the AgentsView pilot and adopted it fleet-wide. All 9 running exe.dev
VMs are configured sources; `rss-feed` is excused as a deployment-lane VM with
no agent harness. Enrolling the last three (`iv-foundry-stage2`,
`iv-entire-agent-shelley`, `telnyx-vm`) required care: `telnyx-vm` runs live
voicemail/SMS forwarding and an in-flight number port, so it got the
`tailscale-api` integration alone rather than the whole `iv` tag, joined with
`--accept-dns=false` to leave `/etc/resolv.conf` pointing at 1.1.1.1, and
received only the AgentsView binaries rather than the full IV layer.

**Retention now has a mechanism, not just a policy.** `agentsview-retention`
runs weekly: it exports sessions older than 90 days to dated Parquet under
`~/archives/agentsview/retired/` — which is in the backup path — and only then
prunes the live SQLite archive. Tiered rather than destructive, because the
driver is exposure (agent history carries prompts, shell commands, and
credentials accidentally shown to tools), not the ~3.3 MB/day of storage.

The DuckDB mirror was considered as the long-term store and rejected. It is a
one-way derived sync from the same SQLite archive, deliberately excluded from
backup as a rebuildable index, would be erased by a routine
`duckdb push --full`, and it flattens machine attribution to the pushing host.
An archive that a documented flag can wipe is not an archive.

First run exported 13 sessions and pruned 11 — two survived with no obvious
exemption (unpinned, non-empty). The script now reports the residual instead of
claiming success, since silently re-exporting the same sessions every week
would look identical to working correctly.

Also in this cycle: ~10.1 GB reclaimed fleet-wide by `prune-disk`; `rss-feed`
rebuilt on a forked exeslim image at 268 MB versus 7.8 GB; and two fail-closed
checks added — `agentsview-coverage` now enumerates the exe.dev inventory
rather than only tailnet peers, and `entire-push-check` asserts no repo holds
an unpushed Entire checkpoint.

## 2026-07-22 — LLM gateway and iv-sandbox decommissioned

Retired the self-hosted Claude/Codex subscription gateway entirely, one day into
its burn-in, after establishing that its premise is outside Anthropic's stated
scope for subscription OAuth.

- **Why.** [Claude Code — Legal and compliance](https://code.claude.com/docs/en/legal-and-compliance)
  states OAuth authentication "is designed to support **ordinary use of Claude
  Code and other native Anthropic applications**", that advertised Pro/Max
  limits "assume **ordinary, individual usage**", that Anthropic "does not
  permit third-party developers … to route requests through Free, Pro, or Max
  plan credentials on behalf of their users", and that it "reserves the right to
  take measures to enforce these restrictions and may do so **without prior
  notice**". The docs tightened ~2026-02-19; enforcement against third-party
  tools using Pro/Max quota began 2026-04-04. CLIProxyAPI is not a native
  Anthropic application.
- **What replaced it: nothing.** The objective was Claude Max available on the
  VM fleet. Running `claude` in a terminal is ordinary use of the native client
  and is fully permitted — Claude Code is already installed and individually
  logged in across the fleet (`install.sh` distributes no Claude credentials).
  The gateway's distinct capability was putting subscription-backed Claude into
  a **non-native** client's model picker (Shelley), which is the part the policy
  addresses. That gap is covered by the hybrid Claude Code → Shelley handoff in
  `model-routing-economics.md`, now understood as permanent.
- **Also answered:** why exe.dev ships a ChatGPT subscription integration but no
  Claude one. OpenAI sanctions a device-code flow for ChatGPT accounts;
  Anthropic offers no third-party equivalent, and building one would make
  exe.dev the prohibited case verbatim. Its `llm` integration is
  `providers=openai(chatgpt:chatgpt)` — 39 models, all OpenAI, zero Anthropic.
- **Decommission order** (dependencies first): deregistered `iv-sandbox` from
  the AgentsView collector and restarted it (8 sources → 7) after confirming its
  4 sessions were already collected through 2026-07-22 02:58; unloaded four
  `com.industryvault.*` LaunchAgents; stopped and deleted both Apple Container
  machines (`iv-sandbox`, `llm-gateway`); removed the plists,
  `~/.config/iv-sandbox/`, and `~/.cli-proxy-api/` (Claude + Codex OAuth
  sessions); deleted both stale tailnet nodes via the Tailscale API.
  `llm-gateway.dojo-sun.ts.net` no longer resolves.
- **Gotcha for any similar teardown.** A healthchecks.io check cannot be paused
  from its ping URL (`/pause` returns 400) — it needs the owning project's API
  key, and the `llm-gateway` project's key was dashboard-only. Expect one
  spurious DOWN alert unless the check is deleted from the dashboard first.
  Likewise, deleting credential files does **not** revoke the underlying OAuth
  sessions; those must be signed out vendor-side.
- **Kept from the abandoned work:** the verified 1Password service-account
  delivery mechanism (now generally applicable, documented in `secrets.md`), the
  secret-placement tiering, and the measured facts about exe.dev's LLM
  integration. `shelley-dual-provider.md` is retained as a closed technical
  record.

## 2026-07-22 — AgentsView pilot collector and canaries live

- Installed AgentsView `v0.38.1` on `klundstedt-mini` through the Homebrew cask
  and added a launchd-supervised, bearer-authenticated collector bound only to
  the mini's Tailscale address. The UI is reachable over MagicDNS and rejects
  unauthenticated API requests.
- Added pinned, checksum-verified amd64/arm64 AgentsView provisioning and a
  fail-closed systemd user source service to `iv-image`. Enabled the first two
  unique-token canaries on `iv-docs` and the `iv-sandbox` Apple Container guest;
  both reject unauthenticated remote-sync requests.
- Verified exact source-to-central fidelity for both canaries and collected 122
  sessions across three machines. Added restrictive remote mirrors, five-minute
  sync scheduling, local collector/sync/snapshot freshness checks, and fixed
  dotfiles' IV-overlay detection so Apple Container guests preserve the
  `iv-image` team layer.
- Added an online SQLite backup staged under `~/archives/agentsview`, excluded
  the live archive/tokens/mirrors from generic backup, and proved the snapshot
  opens through an isolated clean AgentsView server. Remaining pilot gates are
  tracked in `agent_docs/agentsview-pilot.md` and `TODO.md`.

## 2026-07-22 — mini authoring boundary; kgl-dotfiles retired

- Formalized `klundstedt-mini` as the author/merge host for both dotfiles and
  iv-image. GitHub remains canonical; project VMs consume both repositories
  read-only and Linux canaries are created only on demand.
- Mirrored the completed AgentsView pilot work to the mini, archived the VM's
  consistent Shelley database, conversation handoff, and repository bundles
  under `~/archives/vm-retirements/kgl-dotfiles-2026-07-22/`, detached all repo
  integrations, and retired `kgl-dotfiles` and its private Quarto preview.
- Both dedicated writer integrations remain unattached and are reserved for
  explicit temporary push canaries.

## 2026-07-21 — fail-closed, bounded Photos backup gate

- Replaced the ephemeral `uvx osxphotos` invocation with a persistent
  `~/.local/bin/osxphotos` tool environment, provisioned on klundstedt-mini by
  `install.sh` with Python 3.12. This gives macOS a stable executable to grant
  removable-volume access instead of prompting against a transient uvx run.
- Added a 15-minute gate cap clipped to the backup's remaining run-wide budget.
  A small Python supervisor starts osxphotos in its own process group and
  terminates the whole group on timeout, preventing a privacy modal or wedged
  child from holding the Healthchecks run open indefinitely.
- Made every unsafe result fail closed for Photos. Missing tooling, command
  errors (including permission denial), malformed output, timeout, and an
  incomplete library all skip only the Photos sync; archive sources continue,
  then the run pings `/fail` and exits nonzero. Added acceptance coverage for
  all result classes and process-tree cleanup.

## 2026-07-20 — croc file transfer CLI

- **Added `croc` to the personal dotfiles tool layer** — `install.sh` uses
  croc's official checksummed installer for Intel/ARM macOS and Linux without
  consuming the GitHub API quota shared by exe.dev VMs. The provisioning
  manifest declares it as a personal tool, and remote install smoke checks cover
  the command.

## 2026-07-19 — exe.dev website remediation

- **`kgl-dotfiles` now serves a private Quarto documentation site** — committed
  `_quarto.yml` + `index.qmd`, rendering the setup guide, TODO/changelog, and
  selected durable runbooks. `provision-docsite ~/dotfiles` rendered `_site`
  and installed enabled nginx on the proxy port (`0.0.0.0:8000`).
- **`iv-ave-adapters` now serves the same nginx/Quarto pattern** — fast-forwarded
  the VM checkout first, added a searchable project guide/roadmap site, fixed
  its cross-repo README links for rendered use, rendered and provisioned nginx,
  then pushed the repo commit. `iv-home` was deliberately left unchanged and
  its possible retirement is deferred in TODO.
- **Cleaned `iv-docs`'s false failed-unit alarm** — exe.dev already owns port 22
  with `/exe.dev/bin/sshd`; the redundant Ubuntu `ssh.service`/`ssh.socket`
  pair had been enabled and could not bind. Disabled and masked both, matching
  the rest of the fleet. Port 22, Tailscale SSH, and the docs site remained
  healthy; the system failed-unit count is now zero.

## 2026-07-19 — exe.dev fleet web audit

- **All eight running VMs audited end-to-end** — authoritative account inventory
  from `ssh exe.dev ls --json`, tailnet/SSH reachability, local listeners,
  system + user services, and authenticated upstream requests through each
  exe.dev application proxy. Five intended websites are healthy (`iv-gitlake`,
  `iv-docs`, `iv-gitlake-examples`, `rss-feed`, `kgl-thoughts`); both
  `lundstedt.us` custom domains are also healthy. `iv-home` correctly returns
  503 through exe.dev because its enabled service is deliberately tailnet-only.
  `iv-ave-adapters` has no web application or listener configured.
- **`kgl-dotfiles.exe.xyz` explained:** the VM itself and Shelley are healthy,
  but the main URL proxies port 8000 and nothing listens there; Shelley is a
  separate `.shelley.exe.xyz` endpoint and returned 200. Removed the stale TODO
  claiming this VM was not tailnet-joined, and recorded the endpoint model,
  audit matrix, and diagnostic workflow in `agent_docs/exe-dev-web.md`.

## 2026-07-19 — daily fast sync + weekly exact Tigris reconciliation

- The 04:30 backup went DOWN after remaining STARTED for 8h: the Photos data
  transfer had completed, but exact S3 modification-time comparison was still
  issuing per-object HEAD checks (87,322/97,354 complete when diagnosed) at
  abnormal Tigris latency. The job was alive, not deadlocked: approximately
  three checks/second versus roughly 105 on the prior normal night.
- Split the backup into two monitored modes. The daily 04:30 sync uses
  `--update --use-server-modtime`, avoiding per-object HEAD requests while
  retaining full namespace traversal and deletion propagation. A new Sunday
  06:00 exact reconciliation reads rclone's stored source mtimes and catches
  timestamp-preserving/backdated changes. Each has its own LaunchAgent,
  Healthchecks check, success timestamp, log directory, and run-wide deadline
  (2h daily / 18h weekly, below 3h / 20h grace).
- Added visible five-minute one-line stats and made lock/rclone collisions,
  duration exhaustion, failures, and abnormal post-start exits report `/fail`
  and return nonzero. Retained 16 checkers; concurrency was not the root fix.
- Fixed the Photos completeness gate: osxphotos printed status lines before its
  count, so the numeric validation failed every night and silently bypassed the
  guard. It now targets the external library explicitly, mutes status output,
  parses the final count, and pins uvx to Python 3.12 (osxphotos 0.76.1's pyobjc
  dependency fails under the Homebrew Python 3.14 default). Verified the live
  external library reports zero missing personal originals.
- Operational gotcha: editing a shell script while launchd was executing it
  caused the running shell to parse across the replaced file and exit 2 after
  the Photos phase. Never edit/reload the backup while either mode is running.

## 2026-07-17 — embeddings dead-man's-switch (LM Studio outage post-mortem)

- **LM Studio's API server was down 2026-07-14..17 with every check green** —
  the app relaunches at login after a reboot but its server toggle doesn't, so
  semantic_search failed for 2.5 days while the nightly embed steps silently
  skipped (they treat embeddings as best-effort). The mcp-server liveness
  probe counted any HTTP response as healthy and never looked at the
  dependency. Fix in personal-mcp: `healthcheck-mcp.sh` now probes
  `localhost:1234` every 15 min, self-heals via idempotent `lms server start`
  (also covers reboots via the plist's existing RunAtLoad), and pings a new
  **`personal-mcp: embeddings`** check (period 900s, grace 1800s) — created
  via the API, URL in Keychain (`personal-mcp:embeddings-healthcheck-url`),
  registered here in `provisioning/checks.manifest` (drift check green).
  Self-heal verified by stopping the server and watching the probe restore it.
  Lesson added to `agent_docs/monitoring.md`: a liveness probe must cover the
  service's dependencies; best-effort degradation needs its own check.

## 2026-07-17 — herdr provisioned by default (dotfiles + iv-image); mosh on the mini

- **herdr into both tool layers**, superseding the pilot's self-bootstrap-only
  gate (decided before the week-of-use test): `team herdr` row in
  `provisioning/tools.manifest`; floating install in `install.sh` via
  `install_release_asset` (assets are bare version-less binaries
  `herdr-{macos,linux}-{aarch64,x86_64}`, so the /latest/download/ path avoids
  the unauthenticated API rate limit); pinned 0.7.4 in iv-image
  `provision-iv.sh` with per-arch SHA-256s **computed locally at pin time —
  upstream publishes no checksum files**, so every version bump must
  re-download and re-pin. iv-image tests extended (pin presence + smoke).
  Existing VMs pick it up on their next `/upgrade-vm` reprovision; until then
  `herdr --remote` self-bootstrap covers them. Released as **iv-image 2.6.0**
  after the full ritual: local suite + disposable-VM provision/smoke at the
  tagged commit (amd64 live-tested; the arm64 SHA pin is locally computed
  only, exercised on first arm64 provision).
- **Fleet upgraded to 2.6.0 same day** (Path A, all 5 `#iv` VMs: iv-home,
  iv-docs, iv-ave-adapters, iv-gitlake, iv-gitlake-examples) — smoke-healthy,
  `herdr_version=0.7.4` in every lock, overlay re-run after reprovision on
  the 4 VMs that have one (iv-home has no `~/dotfiles`). Gotcha: iv-home's
  first `git fetch` through the repo-integration proxy returned "Repository
  not found" despite the integration being attached; the bare
  `info/refs` probe then returned 200 and the retry succeeded — looks like
  transient integration-proxy flakiness, retry before re-attaching.
- **mosh added to the Brewfile** (formula exception alongside `mas`) as the
  mosh server for Moshi (iOS) → mini; installed on the mini along with herdr.
  Remaining pilot work (Moshi profile, week of real use) stays in TODO.

## 2026-07-14 — iv-image 2.5.1, fleet upgrade, VM retirements, teardown fix

Continuation of the follow-through below, same day:

- **iv-image#4 merged + 2.5.1 tagged** (validation ritual run first): the team
  upgrade-vm skill now mints Tailscale API access from the OAuth client — its
  2.5.0 text still read the revoked static API key, so Path B would have 401'd.
- **All 7 IV VMs upgraded in place to 2.5.1** (Path A; iv-home and qbench-srv
  predated the script model — repo integration attached, cloned at the tag).
  iv-registry's doc site re-rendered.
- **Overlay VMs refreshed to master** (6 VMs). Every one had lost its
  SessionStart/SSH-guard hook splices — root cause: `provision-iv.sh:175`
  installs the team `settings.json` unconditionally, so **any iv-image
  reprovision clobbers the overlay's splices**, and the refresh hook can't
  heal itself from inside the clobbered file. Addressed procedurally:
  upgrade-vm Path A now ends with "re-run the dotfiles overlay if `~/dotfiles`
  exists" in both the dotfiles skill (`d676fc4`) and iv-image's team copy
  (`bef5099`); a merge-instead-of-overwrite in provision-iv.sh stays in TODO
  as the deeper fix. Side effect noted: the run joined iv-registry to the
  tailnet (it wasn't a member; install.sh's normal Linux behavior).
- **Test teardown ghost-node fix**: every VM-creating test (exe, overlay,
  container, sprite) joins the tailnet during install but only destroyed the
  VM — each run left a ghost node and the next join took a `-1`/`-2` suffix
  (three tst-install-exe ghosts + test-iv-overlay observed). `ts_rm_node`
  reuses the OAuth token minted for TS_AUTHKEY, sweeps `^name(-N)?$`, and is
  wired into all eight teardown paths. Verified live: one exe run went 36/36
  and its teardown cleaned four nodes.
- **iv-registry and qbench-srv retired** (VMs + tailnet nodes deleted; local
  SSH state cleaned). iv-registry's only remaining jobs were the hosted doc
  site (dropped — docs readable in-repo; `provision-docsite` on any IV VM
  re-hosts) and a zombie `registry:2` container with no consumers. qbench-srv
  was fully idle. iv-image docs updated (`f3a45ed`). Reviewed and KEPT:
  iv-home (closed-door corporate repo served read-only, tailnet-only) and
  rss-feed (Go feed service for Reeder with its own healthcheck timer — its
  check lives in a separate healthchecks.io project, see monitoring.md).

## 2026-07-14 — post-iv-image follow-through (2.5.0) + /dev/fd procsub bug

The blocked-on-iv-image items, unblocked by the 2.5.0 release:

- **Pin verified current** — 2.5.0 didn't touch the vendored manifests or
  shared AGENTS.md; `diff-provisioning.sh` dual-mode clean, no bump needed.
- **`upgrade-vm.sh` retired** (automated the pre-stock-exeuntu registry flow);
  SKILL.md aligned with the 2.5.0 flow: pinned `--detach` checkout +
  `smoke-provision.sh` in Path A, destroy-VM-before-node-delete ordering and
  exactly-one-hostname-match node query in Path B. Kept the OAuth two-step —
  iv-image's team copy of this skill still references the revoked static API
  key (flagged upstream via TODO).
- **kgl-dotfiles refreshed in place** (5d0f389 → 34560a3). Honest counters,
  the `[!]` gh-unauthenticated line, and the settings-hook sync all visible in
  the live run. The tailscale section took the pre-existing "Already
  connected" early path; the new deeper guard covers the
  rebooted-daemon-but-joined case.
- **Overlay test 20/20 against 2.5.0** (throwaway IV VM).
- **Bare-VM bug found by `test-install.sh exe`:** exe.dev's `ubuntu:24.04`
  image has no `/dev/fd` symlink (`/proc/self/fd` exists; bash hardcodes
  `/dev/fd` for process substitution), so every `<(...)` dies with
  "/dev/fd/63: No such file or directory" — the fd-9 manifest loops had never
  run on that image (the pattern postdates the last exe run). Fixed by
  switching all four loops to `9<<< "$(...)"` here-strings (which use
  pipes/temp files, not /dev/fd), with a blank-first-field guard for the
  empty-substitution edge case. Reproduced and verified on throwaway VMs;
  harness re-run clean.
- **Test-expectation staleness, also caught by the exe run:** the verify list
  expected team skills (mviz, find-skills) on a bare Linux VM — they're
  macOS/iv-image-only by design — and named four tigris skills that upstream
  (`tigrisdata/tigris-agents-plugins`) has since renamed. Now: personal rows
  only, exact names for the dotfiles-owned row, glob for third-party rows.
  And exe.dev's `defaults read` of an unset key now prints `(not set)` with
  rc=0 (was: empty), which `test_no_hook` misread as a registered hook.
- Final board: exe 35/35 VM-side + hook smoke green; ghost tailnet nodes from
  the test runs cleaned via the OAuth flow (test teardown gap noted in TODO).

## 2026-07-13 — hygiene batch: honest errors, CI floor, \_lib.sh everywhere

The "safe now" half of the review-hygiene TODO — items with no dependency on
the in-flight iv-image review session (which owns pin bumps, overlay tests, and
VM refreshes; see the new "Blocked" section in TODO.md).

- **Honest errors in `setup_agents`:** every `>/dev/null 2>&1 || true` around
  `claude mcp add`/`add-json`, hub-mcp (both harnesses), skills installs, and
  the 1Password→Keychain provisioning now prints `[!] <what> failed` on
  non-zero; MCP/skills counters count _successes_ (`N registered, M failed`),
  and the tigris-creds line calls out a partial provision (`4/5 incomplete`)
  instead of staying quiet. Same dishonest-green class as the sync-repos
  listing bug. Verified with the stub harness (stdin-eating `claude`/`npx`
  stubs + CMDLOG): all-success, injected-failure, and Linux scenarios.
- **Regression found by verification, fixed:** `job_kc` propagated `security`'s
  exit 44 when a Keychain item is absent, which killed `set -e` callers —
  the refactored `check-key-expiry.sh` died silently before printing anything.
  `job_kc` now never fails (documented contract: "empty if absent").
- **CI floor** (`.github/workflows/checks.yml`): `bash -n` every script,
  plistlib-validate the LaunchAgents, manifest shape smoke (field counts per
  manifest). Deliberately the no-Keychain/no-VM subset — real drift checks
  stay host-side in `test-install.sh provisioning`.
- **`_lib.sh` adoption:** `owc8tb-unlock.sh`, `check-key-expiry.sh`,
  `check-monitoring.sh`, `diff-provisioning.sh` now source `backup/_lib.sh`
  (`job_kc`/`job_hc*`/new `job_require_mini`/`job_trim`) instead of hand-rolled
  copies; trim idioms unified on `job_trim` (install.sh keeps `mtrim`
  deliberately — must stay self-contained for curl|bash bootstrap).
- **settings.json propagation:** new `sync_claude_settings_hooks` in install.sh
  merges the SessionStart refresh hook + PreToolUse SSH guard from
  `settings.json.example` into an _existing_ live settings.json (seeding was
  only-if-absent, so new hooks never reached existing installs). Idempotent;
  personal Macs only (IV VMs keep the U7 overlay path).
- test-install.sh's VERIFY_SCRIPT tool list annotated as a deliberate smoke
  subset of `provisioning/tools.manifest`.
- Also committed separately (`5061e12`): Linux `setup_tailscale` already-joined
  guard — re-running install.sh on a live VM no longer re-auths (which would
  have replaced the VM's own tailnet node).

## 2026-07-13 — post-plan repo review (3-way audit + fixes)

Fanned three reviewers over docs, scripts, and packages; verified every finding
against the files before acting (`17dedd0`).

- **Bug:** `setup_agents`' `mcp_manifest` was `local` to the Claude block but
  read in the sibling Codex block — under `set -u`, a codex-only machine
  (Claude install failed) died mid-install on an unbound variable. Hoisted;
  failure structure reproduced in a minimal repro before/after.
- **Undeployed skills:** `join-tailnet`/`upgrade-vm` had no `skills.manifest`
  row — installs are fully manifest-driven and stow ignores the skills dir, so
  no machine (including the mini) actually had them installed; they'd only ever
  been run via repo paths. Row added; verified by installing through it.
- Spliced the SSH-guard hook into the mini's live `settings.json` (seeding is
  only-if-absent, so template additions never propagate — general fix parked);
  added `base tailscale` to `tools.manifest`.
- **Doc staleness (10 items):** upgrade-vm SKILL.md taught the _revoked_
  API-key flow (now OAuth two-step; its script flagged legacy — it predates the
  stock-exeuntu model); AGENTS.md claimed Linux SSH config is "written from
  scratch"; README was missing the `provisioning/` row, the U7 overlay
  explanation, readwise, `--upgrade`, the MotherDuck skills row, and a
  monitoring.md link; the backup runbook contradicted itself on the check cron;
  test-install's banner omitted `overlay`; zshrc pointed at a deleted
  wrapper-scripts dir; two dead TODO items; the completed plan's `install.sh:N`
  citations marked as historical.
- Pattern behind most of it: docs _authored_ during the plan stayed accurate;
  docs that merely _describe_ changed things drifted — and several "mark it
  done" edits had silently no-op'd against prettier-padded tables. Standing
  rule now: landing-verify doc edits like code edits.
- Structural findings (working code, no defect) parked in TODO.md "install.sh /
  script hygiene" rather than fixed same-day — see that section.
- **Cross-review follow-up (Codex, same day):** a failure-semantics audit found
  what the staleness-scoped review couldn't — sync-repos treated a missing
  token or failed/empty `gh repo list` as SUCCESS (`return 0`, lastrun written,
  green ping) while an entire org's mirror went stale; with GitHub PATs now the
  fleet's only expiring credentials, that was the exact path an expiry would
  take. Owner-level failures now FAIL loudly (all three paths harness-tested).
  Also: the restore drill's GLACIER fetch failure is now a FAIL, not INFO (the
  "unverified thaw" narrative predated the GLACIER_IR re-tier), and test_exe's
  5×3s SSH retry loop — which violated the repo's own SYN-drop rule — is now
  wait-20s + one attempt + one 30s retry. Dangerous-mode aliases reviewed and
  kept as-is (deliberate solo-operator posture).

## 2026-07-03..13 — simplification plan (all 12 units)

Four core decisions, twelve execution units. The shape of it: dotfiles
declares, iv-image pins, personal-mcp serves.

- **Provisioning became declarative (U2/U3/U4/U5).** New `provisioning/` dir:
  `skills.manifest`, `mcp.manifest`, `tools.manifest` are the single source for
  what gets installed where (`team`/`personal` layers). `install.sh` reads them;
  iv-image's `vendor-skills.sh` vendors skills + a generated `mcp-servers.json`
  from them **at a pinned dotfiles commit** (`dotfiles-manifest.pin`) so the team
  image stays reproducible. `diff-provisioning.sh` (in `test-install.sh
provisioning`) flags drift both ways, including pin lag. Gotcha for the ages:
  manifest read-loops must feed on **fd 9** — `npx` eats stdin and silently
  dropped 34 of 35 rows.
- **personal-mcp split out (U8/U9).** The archives-hub server + ingest pipelines
  moved to the private `kylelundstedt/personal-mcp` repo (filter-repo, history
  preserved) — ends PII shipping to every VM via the public repo. De-dup'd there
  (one `lib/embed.py`, one search CLI, canonical dedup key — the old semantic-
  search dedup was a lossy approximation that could over-collapse SMS). Hub
  rebuild is its own failure-isolated job (a Readwise outage used to silently
  freeze email/calendar search freshness). Cascade re-spaced: msgvault 03:00 →
  web refresh 03:30 → rebuild-hub 04:00 → tigris-backup 04:30 (kills the 04:00
  backup-vs-rewrite collision). dotfiles keeps the hub-mcp _client_ registration
  and the backup.
- **Shared AGENTS.md sections single-sourced (U6).** `provisioning/agents-shared.md`
  is canonical; the personal file embeds it between markers, iv-image vendors it
  at the pin. Reconciled mechanically: 0 rules lost.
- **install.sh is a thin overlay on IV VMs (U7).** Gated on `/exe.dev` +
  `~/iv-provision.lock`: team tools never installed/upgraded over (pins survive),
  team MCP untouched, agents package stowed _around_ the team files with the
  personal AGENTS.md delta + SessionStart hook spliced in, Linux SSH config is a
  prepended marker block that preserves iv-image's stanza (no more truncating
  writes). Verified 20/20 on a throwaway IV VM — the first run caught a real
  stow conflict (settings.json seeding) no sandbox could see.
- **Shared job library (U10).** `backup/_lib.sh` (keychain, healthcheck pings,
  staleness-skip, locks, dated logs, the rclone crypt env shared with
  restore-drill). The month's monitoring rules are library properties now:
  skip-must-ping-success, lastrun-only-on-clean-runs. Two sync-repos plists
  merged into one (both triggers). Verified: env byte-diff, restore drill 3/3,
  both skip paths kickstarted under launchd with pings confirmed via API.
- **Tailscale on a non-expiring OAuth client (U11).** Killed the 2026-08-21 API
  key deadline and both static `iv-internal-*` auth keys. Finding: the client
  secret is NOT accepted as a static API credential — the exe.dev integration
  injects Basic client creds, flows exchange via the proxy for a 1h token, then
  hit the public API. Client needs `auth_keys` AND `devices:core` (write),
  tag:dev. The mini is a _tagged_ device (mbp isn't), so its rebuild mints a
  non-ephemeral tag:dev key via op. Old credentials revoked and verified gone.
- **Credential + monitoring management (U12 + incident fallout).**
  `keys.manifest` + monthly `check-key-expiry.sh` (35d window — must exceed the
  monthly cadence); `checks.manifest` + `check-monitoring.sh` verify every
  healthchecks.io schedule/grace against the live API (read-write key in
  Keychain). Born of the 07-04..09 and 07-11..13 flapping incidents
  (post-mortems in [agent_docs/monitoring.md](agent_docs/monitoring.md)): the
  gitconfig SSH rewrite that only lost the tie under launchd, lastrun-on-failure,
  evicted iCloud files (.Trash, then `iCloud~*` app containers — now excluded
  wholesale), and job reschedules that didn't move their check schedules.
- **Docs cleanup (U1)** and the standing lesson set: verify scheduled jobs via
  `launchctl kickstart`, not shell reproductions of launchd; verify that doc
  edits actually landed (prettier padding silently no-ops exact-match seds).
- Open: one real `./install.sh` run on klundstedt-mbp (U3 verify). iv-image PRs
  #1/#2/#3 merged as the cross-repo halves.

## 2026-06-27

- **klundstedt-mini archive backup → Tigris (done).** `~/archives/` (msgvault email, calendar DuckDB, `speaking-engagements.md`) is inside `$HOME/`, which `backup/tigris-backup.sh` syncs nightly to `tigris:klundstedt-mini-backup` (`bkup:home`) — client-side encrypted via rclone crypt, with nightly Tigris snapshots. No exclude pattern covers `archives/`, so it's fully captured. External-volume archives (aws-s3, box, iphone-backup, messages-store) go to the GLACIER `klundstedt-mini-archive` bucket. Supersedes the original "create bucket + scheduled sync" task.
- **Added `agent_docs/personal-mcp.md`** documenting the `hub-mcp` unified search server, its ingest scripts, and LaunchAgent schedules. Surfaced `hub-mcp` in the README (intro + MCP table). Fixed the `~/archives/calendar-sources/` → `~/archives/calendar/sources/` path in `calendar-refresh.sh`'s comment.
- **Hardened `tigris-backup.sh` for live SQLite.** Added a pre-sync `PRAGMA wal_checkpoint(TRUNCATE)` step for `msgvault.db` (25 GB) and `vectors.db` (1 GB) so rclone copies a consistent single-file snapshot instead of a possibly-torn hot WAL (best-effort; never aborts the backup). Excluded the nightly-rebuilt `archives/hub/hub.duckdb` (+ `.tmp`) from the upload. Ported the remaining hub/personal-mcp TODO items from `~/archives/README.md` (not in git) into the dotfiles `TODO.md`.

## 2026-06-19

- **Documented klundstedt-mini tailscale upgrade ritual** (README + AGENTS.md). `setup_tailscale` is install-if-missing + restart-on-skew — it never `brew upgrade`s, so formula bumps are manual. Because `tailscaled` runs as a root system daemon, `sudo brew services` taints each keg with root-owned binaries and `brew cleanup` can't remove old kegs: ritual is `brew upgrade tailscale` → `sudo brew services restart tailscale` (clears CLI/daemon skew) → `sudo rm -rf /opt/homebrew/Cellar/tailscale/<old-versions>`. Upgraded this host 1.96.4 → 1.98.5 and verified a fresh `install.sh` run leaves it skew-free.

## 2026-06-11

- **iv-image 2.1.0: baked team agent config.** New `agent/` directory: team AGENTS.md, Claude Code settings.json (SSH guard hook), MCP pre-registration (motherduck + github-work via proxy), skills pre-installed at build time. Needed fnm + node install in Dockerfile (exeuntu base doesn't ship node — installed at runtime by exe.dev init). Personal dotfiles layer on top.
- Removed `bootstrap-project`, `data-pipelines`, `exe-dev` skills from dotfiles (not providing enough value; SSH guard hook handles the main exe.dev pain point).
- Gated shared skills in `install.sh` to macOS-only (Linux VMs get them from iv-image).
- Created `join-tailnet` and `upgrade-vm` skills (in iv-image repo + dotfiles). These were documented in tailnet.md but never committed as actual skills.
- Upgraded all three VMs (iv-iv, iv-gitlake, iv-gitlake-examples) to iv-image:2.1.0 using upgrade-vm skill. Re-attached repo integrations and re-provisioned doc sites.
- Renamed `kylelundstedt/iv` repo to `kylelundstedt/iv-docs`. Replaced iv-iv VM with iv-docs VM. Updated exe.dev integration (`github-kylelundstedt-iv-docs`), local clone (`~/github/kylelundstedt/iv-docs`), and remote URL.

### 2026-06-11 — earlier

- **Removed baked Tailscale auto-join — switched to on-demand (iv-image 2.0).** Deleted `ts-bootstrap`/`iv-tailscale-join`/service from iv-image; image now ships `tailscaled` enabled but idle. Cleared the exe.dev `new.setup-script` account default (was `/usr/local/bin/ts-bootstrap`, which silently broke plain exeuntu VMs). Deleted `exe-setup.sh`.
- New `join-tailnet` skill — SSHes into a VM over `*.exe.xyz` and runs `tailscale up` with a one-use key minted via the `tailscale-api` proxy; starts `tailscaled` if not running (works on stock exeuntu too).
- New `upgrade-vm` skill — reprovisions a VM onto a newer image without a `-1` tailnet name: deletes the stale node and tears down the stale SSH master + known_hosts entry before recreating. Migrated `iv-iv`, `iv-gitlake`, `iv-gitlake-examples` to `iv-image:2`.
- `test-install.sh` hook check inverted: now asserts **no** `new.setup-script` hook is registered (auto-join must not silently return).
- Obsoletes the exe.dev metadata-proxy boot delay: on-demand join doesn't run at boot, so the ~90–110s `169.254.169.254` routing delay no longer gates tailnet access.

## 2026-06-10

- Switched to iv-image 1.7 + `ts-bootstrap` as the setup script (deleted `exe-setup.sh`). Fixed stale node race (1.6) and POST retry (1.7).
- Rewrote exe-dev skill setup section for the three-layer model (iv-image → dotfiles → repo clone)
- SSH guard hook in `~/.claude/settings.json` — blocks concurrent SSH to exe.dev hosts

## 2026-05-30

- SSH config: single-source-of-truth rewrite — install.sh generates `~/.ssh/config` from scratch, removed ssh stow package
- Duplicated `exe-setup.sh`'s Tailscale proxy / auth-key / ghost-node logic into install.sh's `setup_tailscale` so install.sh works standalone. (`exe-setup.sh` itself remains in the repo — it's the URL artifact exe.dev's default-setup-script hook fetches at first boot. The 93e4076 deletion of the file was a regression; restored same day along with a smoke test in test-install.sh.)
- Fixed `User exedev` scope — was `*.exe.xyz *.ts.net` (applied to all tailnet hosts incl. Macs), now `*.exe.xyz` only
- Pre-seed exe.dev host key in known_hosts (wildcard `*.exe.xyz` entry, no more `StrictHostKeyChecking=accept-new`)
- `TS_HOSTNAME` defaults to `$(hostname)` so Tailscale name always matches VM name
- Dynamic SSH routing for tag:dev tailnet peers — `Match host *.ts.net exec` block + `~/.local/bin/ssh-tailnet-tagged` helper. `ssh <vm>` now Just Works for any current/future exe.dev VM without re-running install.sh per host. Host-key checking disabled for matched hosts (WireGuard is the trust anchor).
- test-install.sh: `test_hook_url` + `test_hook_registration` smoke checks. The second one catches drift between `exe-setup.sh` (fast, Tailscale-first ~6s) and `install.sh` (slow, Tailscale-last ~34s) being registered as the hook — both are functional, so the failure mode is silent slowness, not breakage.
- Re-registered exe.dev hook to `exe-setup.sh`. Had drifted to `install.sh` (likely during 93e4076's "fold exe-setup.sh into install.sh"). VMs were bootstrapping but taking ~34s to tailnet instead of ~6s. Measured 5.84s peer-visible after fix.

## 2026-05-23

- install.sh: skip redundant downloads on exeuntu (`need` guards, skip apt-get when packages present)
- install.sh: skip Codex MCP add on non-interactive sessions (was hanging on headless VMs)
- install.sh: `User root` → `User exedev` in SSH config (Tailscale SSH hangs as root on exeuntu)
- install.sh: GitHub MCP servers via exe.dev HTTP proxy on VMs (`github-mcp-home`, `github-mcp-work`)
- install.sh: MotherDuck MCP via exe.dev HTTP proxy on VMs (`motherduck-mcp`)
- exe.dev default setup script (`exe-setup.sh`): Tailscale via API proxy, ghost node cleanup, dotfiles
- `tailscale-api` HTTP proxy integration on exe.dev — no secrets on VM
- exe-dev skill updated with MCP proxy setup and bootstrap flow
- agent_docs: rewrote secrets.md and linux.md for exe.dev era
- sync-repos.sh: fast-forward default branch after fetch; split work repos by org; added USAA org
- Restructured `~/github/` from flat `klundstedt/` to per-org directories (IndustryVault, iv-cmg, USAA)

## 2026-05-20

- Zed: removed `agent_servers` ACP block (Anthropic billing change)
- Zed: `skip-worktree` for `ssh_connections` — no more git churn
- install.sh: `gh` CLI auth via OAuth (macOS) or PAT (Linux)
- install.sh: native Codex binary (brew cask on macOS, GitHub release on Linux)
- install.sh: OAuth MCP servers for Codex (motherduck, tigris, readwise)
- Recovered missing `github-home` MCP on klundstedt-mini
- `zsh/.profile`: documented `GITHUB_TOKEN` export rationale

## 2026-05-01

- **exe.dev consolidation.** Decision: exe.dev is the primary dev-VM platform; Apple Containers and Sprites on back burner. Demoted `apple-containers`/`sprites-dev` in `CLAUDE.md`/`AGENTS.md` to "alternative, not actively maintained"; marked `test-install.sh`'s Apple Container and Sprite paths informational.

## 2026-04-20

- Snowflake CLI (`snow`) via `uv tool install`

## 2026-04-12

- Unified SSH agent forwarding across all three VM platforms
- Login-time commit signing hook in .zshrc
- SSH hostname canonicalization for MagicDNS
- Kernel-mode tailscaled on exe.dev

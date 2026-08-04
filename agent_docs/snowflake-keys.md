# Snowflake Accounts & Key-Pair Inventory

The four Snowflake accounts, how to reach each one programmatically, what
key-pair authentication is registered where, and the closed-out provenance of
the `rsa_key` orphan. Written 2026-07-31 from `klundstedt-mini`.

This exists because an unidentified RSA key in `ssh-add -l` cost two sessions to
identify, and the answer — "it is not an SSH key at all" — is not derivable from
anything in this repo. Credential-placement policy lives in
[secrets.md](secrets.md); this file is the Snowflake-specific inventory.

## Accounts

Verified 2026-07-31 by `SHOW ACCOUNTS` as `ORGADMIN` in MAIN. There are exactly
four. **`CLIENTX`, named in the MAIN admin item's `org_control` field, does not
exist** — treat that note as aspirational.

| Account   | Locator  | Account identifier        | Cloud / region | Created    | Admin MFA       |
| --------- | -------- | ------------------------- | -------------- | ---------- | --------------- |
| MAIN      | DJA78347 | `INDUSTRYVAULT-MAIN`      | not recorded   | 2019-10-07 | password + TOTP |
| SHARED    | ROB18784 | `INDUSTRYVAULT-SHARED`    | AWS us-west-2  | 2022-10-13 | password + TOTP |
| CMG_SDW   | AK97040  | `INDUSTRYVAULT-CMG_SDW`   | Azure westus2  | 2024-01-05 | password + TOTP |
| SHARETEST | YC59469  | `INDUSTRYVAULT-SHARETEST` | Azure westus2  | 2026-06-03 | password + TOTP |

MAIN holds `ORGADMIN` over the other three. All non-root MAIN users are disabled
by design.

## Reaching them programmatically

Break-glass admin items live in 1Password **`Root Only`**; the named key-pair
item lives in **`Employee`**. Two things about them are load-bearing:

**All four accounts can be driven headlessly.** `op item get <id> --otp` plus
the connector's `passcode=` parameter is sufficient for every one of them.

> **Corrected 2026-08-02.** This section previously claimed SHARETEST's MFA was
> a device-bound **native passkey** with no headless path, which is why it sat
> unswept for weeks. It is **TOTP**, enrolled in the 1P item's one-time-password
> field. The item's own `authenticator` and `mfa_note` fields carried the stale
> passkey claim — the note even read "consider also enrolling TOTP" — and the
> doc inherited it; both have now been corrected in 1Password.
>
> Two gotchas when connecting, both cost a failed attempt:
>
> - Log in as the **`login_name`** (`support+sharetest@industryvault.com`), not
>   the Snowflake NAME (`ADMIN`). Same pattern on SHARED.
> - Use plain password auth plus `--mfa-passcode`. Passing
>   `--authenticator username_password_mfa` fails with a misleading
>   "Incorrect username or password".

**`SNOWFLAKE.ORGANIZATION_USAGE` is not enabled**, even from MAIN as `ORGADMIN`
(`Object 'SNOWFLAKE.ORGANIZATION_USAGE.USERS' does not exist or not
authorized`). There is therefore **no single org-wide user query** — every sweep
is per-account, one login each. Do not plan work that assumes otherwise.

### Two item defects that cost a failed login each

Both items document a Snowflake user NAME that is rejected at login. The
`username`/email field is what actually works; `current_user()` then reports the
NAME.

| Item                             | Field says   | Actually works                     |
| -------------------------------- | ------------ | ---------------------------------- |
| `Snowflake SHARED - admin`       | `ADMIN`      | `support+shared@industryvault.com` |
| `Snowflake CMG CLI - klundstedt` | `klundstedt` | `KLUNDSTEDT@INDUSTRYVAULT.COM`     |

The SHARED item's notes already carried a "confirm" caveat on this; it is now
confirmed wrong. The CMG defect was found by the 2026-07-30 session; the working
login name is verified here.

**The CMG p8 attachment moved sections.** The reference is
`op://Employee/lohlzp32a4fuzxttegbxuzrguy/Key-pair/p8` — an earlier session
recorded `private_key`, which no longer resolves. Get the current path from the
`files[].section.label` in `op item get --format json` rather than trusting a
hard-coded reference.

**This CMG key also lives on `klundstedt-mbp` at `~/private_key.p8`** — the same
key (Snowflake fingerprint `SHA256:Y30BLsi8/…`, verified 2026-08-03 against this
item's `RSA_PUBLIC_KEY_FP`, the item's own p8 attachment, and the live CMG_SDW
registration for `KLUNDSTEDT@INDUSTRYVAULT.COM`), encrypted PKCS#8, mode 0600.
It is the keyfile for the **`default` dbt profile** (`~/.dbt/profiles.yml` →
`private_key_path: ~/private_key.p8`, passphrase from the `PRIVATE_KEY_PASSPHRASE`
env var at runtime, not stored beside the key), used across the `dbt_cmg_*`
repos. **Kept deliberately — it is an active credential, not stray key
material.** The authoritative copy and its passphrase are in this 1P item, so the
on-disk file is reproducible; it is safe to delete only if dbt is first
repointed to source the key from 1Password at runtime.

## Key-pair registrations, 2026-07-31

Every user enumerated with `SHOW USERS` then `DESC USER` under `ACCOUNTADMIN`,
**zero `DESC` failures** in all three — so these are complete, not sampled.

| Account   | Users | Users holding a key | Registrations |
| --------- | ----- | ------------------- | ------------- |
| CMG_SDW   | 96    | 9                   | 9             |
| MAIN      | 10    | 1                   | 1             |
| SHARED    | 4     | 1                   | 1             |
| SHARETEST | 2     | **0**               | 0             |

CMG_SDW holders (all enabled; `CMG_DATACLOUD_DEV_SERVICE_ACCOUNT` and
`CMG_DATACLOUD_DEV_USER` **share one fingerprint**, so 9 registrations span 8
distinct keys):

```
AKILLINGER@INDUSTRYVAULT.COM        SHA256:CaSEEyyLRdSD5o+/VAeC+rCGTPx/VJW+dLUTGCTpSdI=
CJMBAGWUH@INDUSTRYVAULT.COM         SHA256:3bbBo5NpilQk22a6Nr8al5t1h7saSPtQI0c563kPqHY=
CMG_DATACLOUD_DEV_SERVICE_ACCOUNT   SHA256:LZihkJmS2cjgbFTVuX5R4KB8JWWidRBuuIA4JgqzwWY=
CMG_DATACLOUD_DEV_USER              SHA256:LZihkJmS2cjgbFTVuX5R4KB8JWWidRBuuIA4JgqzwWY=
CMG_FIVETRAN_USER                   SHA256:Jd5jEB3j+qFVOY/ZlfkQqceNJ0cu3Hcl3VisRJEVWqo=
DATAHUB_USER                        SHA256:p2EFywuqMkYnnHG4OxuuG4n+Pb9GykU3P24YJycIcx0=
DKILLINGER@INDUSTRYVAULT.COM        SHA256:9+76eW/OLpPIbE+M0ff0h+MTc8w8EnQbXRK1RnCvacc=
GITHUB_ACTIONS_SERVICE_ACCOUNT      SHA256:tJASPeuUqnAHjH40bMAlfhJntkFZT6O8Bf/9TtsFVIY=
KLUNDSTEDT@INDUSTRYVAULT.COM        SHA256:Y30BLsi8/IfY6CHSZMHJ8hizBdZhYgFZS069OxVWzSk=
```

MAIN: `KLUNDSTEDT@INDUSTRYVAULT.COM`, **disabled**,
`SHA256:NrIShgLiyeHn67C3/HxIZopEKqoSaqSZAUTJhMTvzCc=`.
SHARED: `KLUNDSTEDT`, `SHA256:SyKWSjPaLHnjJMQXppJaA7PVDu+iR/xq1s8/0iboYo4=`.

No user named `%SQLMESH%` exists in any of the three.

## The `rsa_key` orphan — closed 2026-07-31

**It was never an SSH key.** It is a Snowflake key-pair-authentication key, and
it appeared in `ssh-add -l` only because the 1Password agent publishes every
`SSH_KEY` item in the vault. That is the whole trap: a key with no
`~/.ssh/config` entry, no `known_hosts` host, and no git remote still shows up in
the agent listing on every Mac, looking exactly like an unaccounted-for SSH
credential.

Two 1Password items in `Employee` held **the same RSA-2048 key** — identical
modulus, differing only in stored encoding (PKCS#8 vs OpenSSH):

| Item                                  | ID                           | Created (UTC)        |
| ------------------------------------- | ---------------------------- | -------------------- |
| `rsa_key`                             | `kphyzpgprklwqjovumbms7pas4` | 2024-12-12 02:16:00Z |
| `sqlmesh_user Snowflake RSA Key Pair` | `p4ouquhmblkh7yykf3f2gndlee` | 2024-12-12 02:29:10Z |

- SSH fingerprint: `SHA256:eIWJ+NokgJH6gA+HelkMSyNf5FbEG6WGQ92ccgF3Xe0`
- Snowflake fingerprint: `SHA256:k6bqs5g72OhYw4WP9taBlVd55qk01TywDUloFHzjlwI=`

**Provenance.** `kylelundstedt/servicemac_acdc/provision/sqlmesh_snowflake_setup.py`
creates a Snowflake service user `sqlmesh_user` and runs `ALTER USER … SET
RSA_PUBLIC_KEY`. The key reaches it as `SNOWFLAKE_SQLMESH_KEY` from Doppler
project `servicemac_acdc`, config `dev_personal` (`doppler.yaml`, `.envrc`). The
repo has been dormant since 2025-04-19.

**Which Snowflake account it targeted is still unproven.** The identifier lives
only in that Doppler config, and the Doppler credential in 1Password
(`dopper_token_servicer_oversight`) is a `dp.st.` **config-scoped service token
for a different project**, so it cannot read it. Confirming would need an
interactive `doppler login`.

**Negative results.** On `klundstedt-mini`: no reference in `~/.ssh/config`,
`known_hosts`, any `authorized_keys`, any git remote (all remotes are HTTPS —
see [git-https-migration.md](git-https-migration.md)), anywhere on the
filesystem, or in the git history of dotfiles or any `~/github` repo. GitHub
authenticates with the ed25519 key; the RSA key is never offered. Not registered
on any user in CMG_SDW, MAIN, or SHARED.

**Resolution.** Both items are **archived, not deleted** — restorable from the
1Password Archive. The named copy was archived 2026-07-31 20:44Z by an earlier
pass (which also archived the 4096-bit `Snowflake Key-Pair` orphan); `rsa_key`
was archived 2026-08-01 00:45Z. `ssh-add -l` on the mini now lists only the three
ed25519 keys, which is the intended steady state.

**Decided 2026-08-04: both stay archived. Item closed.** The alternative was to
restore `sqlmesh_user Snowflake RSA Key Pair` as the canonical record and leave
only the badly-named `rsa_key` duplicate archived. Rejected because restoring
either one puts a key back into `ssh-add -l` that is registered on **no user in
any of the four accounts** — CMG_SDW, MAIN and SHARED were swept 2026-07-31,
SHARETEST on 2026-08-02 (two users, `has_rsa_public_key = false` for both). A
key visible in the agent listing but registered nowhere is precisely the shape
that made this an investigation in the first place; restoring it would reseed
the same confusion for the next sweep.

If `servicemac_acdc` is ever revived, generate a fresh key rather than
resurrecting this one — it is dormant since 2025-04-19, and **which Snowflake
account it targeted was never proven** (the identifier lives only in the Doppler
`servicemac_acdc` / `dev_personal` config, unreadable with the config-scoped
token stored in 1Password). Closing this item accepts that unknown permanently
rather than leaving it open indefinitely for a key that grants nothing.

**No remaining doubt — SHARETEST was swept 2026-08-02 and is clean.** The
account holds exactly two users, `ADMIN` and `AKILLINGER`, and `SHOW USERS`
reports `has_rsa_public_key = false` for **both**. There is no `sqlmesh_user`
and no key-pair auth anywhere in the account, so `SHA256:k6bqs5g7…` is not
registered there. Every one of the four accounts has now been checked.

## Sweeping an account for a fingerprint

The method, so this does not have to be rebuilt:

1. Convert the key to Snowflake's fingerprint form — it is **not** the SSH
   fingerprint. Base64 of the SHA-256 of the DER `SubjectPublicKeyInfo`:

   ```python
   der = k.public_key().public_bytes(Encoding.DER, PublicFormat.SubjectPublicKeyInfo)
   "SHA256:" + base64.b64encode(hashlib.sha256(der).digest()).decode()
   ```

2. Connect as `ACCOUNTADMIN`; `SHOW USERS`, then `DESC USER "<name>"` per user.
3. Compare against **both** `RSA_PUBLIC_KEY_FP` and `RSA_PUBLIC_KEY_2_FP` —
   Snowflake supports two keys per user for rotation, and checking only the
   first will miss a live registration.
4. Count and report `DESC` failures. A sweep that silently skips users it could
   not describe is not a negative result.

Use the Snowflake CLI's interpreter (`~/.local/share/uv/tools/snowflake-cli/bin/python`);
it already has `snowflake-connector-python` and `cryptography`. Keep private key
material in memory — stream it from `op read` into stdin, never to disk.

**Watch out:** a scratch file named `inspect.py` in the working directory
shadows the stdlib `inspect` module and breaks `cryptography`'s imports with a
confusing traceback.

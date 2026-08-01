# SSH Key Inventory & the Mini's Inbound Surface

Every SSH private key this account holds, what each one authenticates, and the
three separate inbound SSH paths into `klundstedt-mini`. Written 2026-07-31
from the mini, after a JumpCloud reconciliation that deleted three stale key
registrations.

This exists because the JumpCloud registrations were **invisible from the
repo**: nothing in dotfiles referenced them, they were pushed onto the host by
an agent rather than written by `install.sh`, and the private halves had been
gone for years. The negative results below — the places a key is _not_ — are
the expensive part and the reason to keep this file. Credential-placement
policy lives in [secrets.md](secrets.md); Snowflake key-pairs (which are not
SSH at all) live in [snowflake-keys.md](snowflake-keys.md).

## Current keys — all three, all in 1Password

There are **no private key files in `~/.ssh` on the mini** — verified; the mbp
was not inventoried (see the last section). Every usable key lives in the
1Password `Employee` vault and is served by the 1Password SSH agent, which
`~/.ssh/config` wires up via a global `IdentityAgent`. That part is
machine-independent and therefore settled for both Macs.

| Fingerprint                                          | Type    | 1P item (`Employee`)             | Authenticates                                                             |
| ---------------------------------------------------- | ------- | -------------------------------- | ------------------------------------------------------------------------- |
| `SHA256:ioXXRYB9piC+4+sjFoVrQnte4pDgba3G/XYoLsQRgVU` | ed25519 | SSH Key - GitHub (kylelundstedt) | GitHub (SSH remotes; all repo remotes are HTTPS)                          |
| `SHA256:gMRe/DbjCc48fc2S64CytPunnsV+h57WbU3fCqqStwE` | ed25519 | SSH Key - exe.dev                | the exe.dev **control plane** + all VMs                                   |
| `SHA256:S8bDr6M8p5V4+NnU0Bvyj9c/DrDGsouqcPzNPUYOtM0` | ed25519 | SSH Key - iv-klundstedt-2024-01  | Macs fallback + Moshi phone path; also an AWS EC2 key pair in `us-west-2` |

Those are the only three `SSH_KEY` items across all 190 items in all four
vaults (`gitlake-spikes`, `Employee`, `Principals Only`, `Root Only`). The
exe.dev key's blast radius is why `ForwardAgent` is scoped so tightly in
`~/.ssh/config` — see [exe-dev-remediation.md](exe-dev-remediation.md).

## The three JumpCloud registrations — deleted 2026-07-31

JumpCloud user `JC IV - klundstedt` had three SSH keys registered. The JC agent
(`com.jumpcloud.darwin-agent`, running on both Macs) pushes registered keys into
`~/.ssh/authorized_keys` on every JC-managed device, so each was a **live
inbound credential** on both Macs.

| JC registration         | Enrolled   | Fingerprint                                          | Type     | Private half  |
| ----------------------- | ---------- | ---------------------------------------------------- | -------- | ------------- |
| `iv-klundstedt`         | 2019-03-09 | `SHA256:lLwdqcogkqC2r8wsBoM01TxDBRgqe/Qp2LTZmvj3LxE` | RSA-2048 | **not found** |
| `iv-klundstedt-2020-02` | 2020-02-21 | `SHA256:VrqTiPtJo5EATgk/LxCQG5lXJKLAZt5Q4/5lLowTaGo` | RSA-2048 | **not found** |
| `iv-klundstedt-2022-11` | 2022-10-28 | `SHA256:c+2b39L9VGiSgJ+LQVpZcZVXHMxtx1CazwdvURsX8F0` | ed25519  | **not found** |

The 2020 key carried the comment `kyle@kyle-imac` in its pushed blob — the
mapping to the `iv-klundstedt-2020-02` registration was inferred (three
registrations ↔ three pushed keys, the other two name-matched exactly) and was
never confirmed in the console before deletion. Moot now, but don't treat that
row as directly verified.

**All three deleted from JumpCloud 2026-07-31.** The JC agent reconciled within
minutes: `~/.ssh/authorized_keys` on the mini is now header-only, zero keys.
`~/.ssh/authorized_keys.jcorig` — the JC agent's manual-additions file, which it
merges into `authorized_keys` — was and remains empty.

### Why the current key was NOT registered in its place

The obvious move is to register `iv-klundstedt-2024-01` and retire the olds.
That is wrong here, because **no path you actually use reads `authorized_keys`
at all**:

- mbp → mini is **Tailscale SSH** (`RunSSH: true`), which authenticates at the
  tailnet ACL layer and ignores `authorized_keys` entirely.
- iPhone → mini is the **separate sshd on 2222**, which reads
  `authorized_keys_moshi`, not `authorized_keys`.
- exe.dev VMs use the exe.dev key against the VMs' own `authorized_keys`.

Registering in JC would have pushed the current key back into the same
LAN-facing file on _every_ JC-managed device, recreating the exact standing
credential being retired, for no gain. If a break-glass local key is ever wanted
on one host, the right place is `~/.ssh/authorized_keys.jcorig` — local, not a
fleet-wide registration.

There is also **no JumpCloud-managed server fleet**. `known_hosts` and shell
history are entirely exe.dev VMs, `github.com`, and `klundstedt-mini`; the only
JC-managed systems are the two Macs.

## The mini's three inbound SSH surfaces

Worth stating explicitly because they are independent daemons and it is easy to
assume changing one affects another. It does not.

| Surface             | Daemon                       | Port / bind                 | Authorized-keys file                |
| ------------------- | ---------------------------- | --------------------------- | ----------------------------------- |
| Tailscale SSH       | `tailscaled` (in-process)    | tailnet only                | none — tailnet ACLs                 |
| Moshi bootstrap     | `dev.klundstedt.sshd-moshi`  | `100.123.154.23:2222`       | `.ssh/authorized_keys_moshi`        |
| Native Remote Login | `com.openssh.sshd` (launchd) | `*:22` — **all interfaces** | `.ssh/authorized_keys` (JC-managed) |

Native Remote Login was the exposure: bound to every interface (confirmed
reachable on the LAN address `192.168.1.165:22`), offering
`publickey,password,keyboard-interactive`, and its _only_ valid public keys were
the three stale JC ones. `PasswordAuthentication` is not set anywhere in
`sshd_config` or `sshd_config.d/100-macos.conf`, so it ran at the macOS default
of enabled.

**Decided 2026-07-31: turn Remote Login off on the mini.** With the JC keys
deleted the file is empty, so port 22 grants nothing by pubkey — but it still
answers on the LAN with password auth enabled, and nothing uses it.

```
sudo systemsetup -f -setremotelogin off      # off
sudo systemsetup -f -setremotelogin on       # re-enable if ever needed
```

Tailscale SSH and the moshi sshd are unaffected — `tailscaled` implements its
own SSH server rather than proxying to `sshd`, and the moshi daemon is a
distinct LaunchDaemon with its own config. The moshi path on 2222 is the
deliberate break-glass route if Tailscale SSH is ever unavailable.

> **PENDING as of this writing** — the command needs interactive `sudo`, which
> an agent session can't supply. Verify with
> `nc -z 127.0.0.1 22` (should fail) and flip this note when done.

## What was searched (and came up empty)

The value here is the exhaustiveness, so that a future session doesn't repeat
it. Scanned on the mini 2026-07-31 for the three JC fingerprints:

- `~/.ssh` — no private keys of any kind.
- `ssh-add -l` — the three 1P keys above, nothing else.
- All four 1Password vaults, all categories — three `SSH_KEY` items, no JC key
  stored as a Document or Secure Note either.
- Full `$HOME` content grep for `BEGIN * PRIVATE KEY` headers.
- `/Volumes/OWC8TB` (incl. `Box_Download_2025-01-12`) — TLS keys and old EC2
  keypairs only.
- iCloud Drive (`~/Library/Mobile Documents`) — nothing key-shaped.
- Time Machine — no destinations configured, so no historical copy exists.

Non-JC private keys that **do** exist on the mini, none of which grant access to
anything current:

- `~/.orbstack/ssh/id_ed25519` (`SHA256:yBAFJAGHJ1R+/JprZEhYOEAXwMRS0BmGj2hSkAvJQKw`)
  — OrbStack-generated, self-managed.
- ~10 RSA-2048 `.pem` files under `Documents/`, `Downloads/`, and `OWC8TB` —
  decommissioned EC2 keypairs (`industryvault.internal`, `loancare`, `ccap`)
  and expired TLS keys, all from 2017–2018 infrastructure.

### Two cleartext private keys in the email archive

`~/archives/email/attachments/` holds two **unencrypted RSA private keys** that
arrived as email attachments — `SHA256:xzA5QeaMFq2JvPxmqq89HWT7aJkCNwJ6Psw3vKF53Ik`
(`dchristensen.key`) and `SHA256:R474HcGSATFlS5AIQ8ZYXKdjs5PcukujPsts8V6BzTA`.
Both are third-party and unrelated to any IV system, but `~/archives` is in the
Tigris backup path ([tigris-backup-runbook.md](tigris-backup-runbook.md)), so
they are being replicated off-machine. Open item in [TODO.md](../TODO.md).

## mbp

Not covered by this sweep. `klundstedt-mbp` has Remote Login **off** already
(connection to `klundstedt-mbp.dojo-sun.ts.net:22` times out), so the JC keys
were never a live inbound path there, and the JC deletion removes them from its
`authorized_keys` on the agent's next sync regardless. The 1Password result is
machine-independent and already settles that half for both Macs. What remains is
an on-disk `~/.ssh` inventory run locally on the mbp — see [TODO.md](../TODO.md).

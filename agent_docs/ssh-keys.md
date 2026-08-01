# SSH Key Inventory & the Mini's Inbound Surface

Every SSH private key this account holds, what each one authenticates, and the
separate inbound remote-access paths into `klundstedt-mini` — which of them are
still open and why. Written 2026-07-31 from the mini, after a JumpCloud
reconciliation that deleted three stale key registrations and closed two
LAN-facing services.

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

## The mini's inbound remote-access surface

Worth stating explicitly because these are independent daemons and it is easy
to assume changing one affects another. It does not — turning Remote Login off
left both remaining paths untouched.

State after the 2026-07-31 cleanup:

| Surface             | Daemon                       | Port / bind               | Credentials                         | State   |
| ------------------- | ---------------------------- | ------------------------- | ----------------------------------- | ------- |
| Tailscale SSH       | `tailscaled` (in-process)    | tailnet only              | none — tailnet ACLs                 | **on**  |
| Moshi bootstrap     | `dev.klundstedt.sshd-moshi`  | `100.123.154.23:2222`     | `.ssh/authorized_keys_moshi`        | **on**  |
| Native Remote Login | `com.openssh.sshd` (launchd) | `*:22` — all interfaces   | `.ssh/authorized_keys` (JC-managed) | **off** |
| Screen Sharing      | `com.apple.screensharing`    | `*:5900` — all interfaces | macOS account password              | **off** |

Native Remote Login was the exposure: bound to every interface (confirmed
reachable on the LAN address `192.168.1.165:22`), offering
`publickey,password,keyboard-interactive`, and its _only_ valid public keys were
the three stale JC ones. `PasswordAuthentication` is not set anywhere in
`sshd_config` or `sshd_config.d/100-macos.conf`, so it ran at the macOS default
of enabled.

**Remote Login turned OFF on the mini 2026-07-31.** With the JC keys deleted
the file is empty, so port 22 granted nothing by pubkey — but it still answered
on the LAN with password auth enabled, and nothing used it. Verified after:
`nc -z 127.0.0.1 22` fails, `com.openssh.sshd` is fully unloaded
(`Could not find service ... in domain for system`), and `2222` still listens.

Tailscale SSH and the moshi sshd were unaffected, as expected — `tailscaled`
implements its own SSH server rather than proxying to `sshd`, and the moshi
daemon is a distinct LaunchDaemon with its own config. The moshi path on 2222
is the deliberate break-glass route if Tailscale SSH is ever unavailable.

**Toggle it from the GUI, not the CLI.** `sudo systemsetup -f -setremotelogin
off` fails with _"Turning Remote Login on or off requires Full Disk Access
privileges"_ — the FDA has to belong to the calling terminal. Don't grant it:
that capability is inherited by every process the terminal spawns, including
every agent session, which is a permanent broad read grant in exchange for one
toggle. Use **System Settings → General → Sharing → Remote Login** instead.
(A `launchctl disable system/com.openssh.sshd` + `bootout` override also works
without FDA and persists, but a major macOS update can reset overrides.)

### Screen Sharing — also turned off, on a weaker argument

Turned off the same day. Unlike SSH there was **no defect** here: no legacy VNC
password file existed, so auth was macOS account credentials rather than a weak
VNC secret; Remote Management/ARD was never enabled (`ARDAgent` not loaded, no
`com.apple.RemoteManagement` domain). The case was pure surface reduction — one
more authenticated service on `*:5900`, reachable from anything on the LAN, on
a host whose Application Firewall is disabled — plus `screensharingd` showing
**zero log entries in 14 days** and the mini having physical displays (Studio
Display + a 4K) to re-enable from.

**The cost, which is real:** this removes the only remote GUI path to the mini.
The recurring case is unlocking 1Password — see the `new-dev-vm` preflight
blocker in [TODO.md](../TODO.md), which refuses when the agent can't sign. If
that happens while away from the machine, it now waits until you're back. Turn
Screen Sharing back on in **System Settings → General → Sharing** if that
becomes a pattern; it was a judgment call, not a defect fix.

**There is no tailnet-only middle setting.** Screen Sharing binds all
interfaces with no interface option; the macOS Application Firewall is per-app
(blocking `screensharingd` is equivalent to turning it off); only custom `pf`
rules could scope 5900 to `utun`, and those are reset by macOS updates. On or
off are the real choices.

### What still listens on all interfaces

After both toggles, the only non-loopback, non-tailnet listeners left are Apple
platform services this repo doesn't configure: `ControlCenter` on `:5000` and
`:7000` (AirPlay Receiver), `rapportd` on a high port (Continuity/Handoff), and
`:88` (local KDC). Everything this repo owns is either loopback (`hub-mcp`
`:8765`, AgentsView collector `:8080`) or bound to the Tailscale address
(`:2222`, and `:443`/`:8443` from `tailscale serve`).

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

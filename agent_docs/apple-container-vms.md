# Apple Container VMs — creating & using (exe.dev-equivalent)

> Status: verified on `klundstedt-mini` 2026-07-19, macOS 26.5.2,
> `apple/container` 1.0.0 (Kata guest kernel). This is the AC counterpart to how
> we create/use exe.dev VMs (`exe-dev` skill, `exe-dev-web.md`). First working
> instance: `iv-sandbox` (a local Shelley VM). The `apple-containers` **skill**
> predates this and uses the older `container run` + `ubuntu` path — this doc is
> the current, machine-mode approach; update the skill to match.

## What this gives you

A local, hardware-isolated microVM that reproduces an exe.dev VM with **no
dependency on the exe.dev control plane**: the exeuntu base image, full systemd,
the Shelley harness, a tailnet identity, and an HTTPS URL — all on owned Mac
hardware. Demo delta vs. a real exe.dev VM: no control plane (provisioning
injection, OIDC proxy, LLM gateway, VM lifecycle), and a different guest kernel.

## `container run` vs `container machine` (pick machine for exe.dev-equivalence)

- `container run` — one process in a microVM; the Kata static kernel, no
  systemd. Fine for throwaway command execution (the old skill's path).
- `container machine` — boots the **image's own `/sbin/init`**, so **full
  systemd works**. This is required for the exeuntu image (Shelley runs under
  systemd socket activation). Use machine mode for any exe.dev-equivalent VM.

## Prerequisites (host, one-time)

```bash
brew install --cask container         # or via install.sh --apps
container system start                # first run downloads the Kata kernel (prompts Y/n)
sudo pmset autorestart 1              # auto power-on after power loss (needs a real TTY)
```

Two macOS-GUI settings that the CLI cannot set and that **silently block
unattended operation** if missing:

1. **Auto-login** (System Settings → Users & Groups) — user-domain LaunchAgents
   (VM boot, services) only load at login.
2. **App Data Protection / Full Disk Access for the container helpers**
   (`container-runtime-linux`, `container-apiserver`). On macOS 26 the first VM
   boot triggers permission prompts; until answered, every boot/exec **hangs and
   dies with an XPC timeout**. Grant them so it persists across reboots.
   **The prompt recurs per NEW VM**, not just per install — creating a second
   machine (llm-gateway, 2026-07-21) XPC-timed-out its first boot until a fresh
   `container-runtime-linux` prompt was approved. Expect one prompt per
   `machine create`.

## Creating a machine (worked example: iv-sandbox)

```bash
# 1. Pull the base image and CONFIRM it is arm64 (exeuntu ships a multi-arch
#    index with a native arm64 variant — no local rebuild needed).
container image pull ghcr.io/boldsoftware/exeuntu:latest
container image inspect ghcr.io/boldsoftware/exeuntu:latest | jq '.[0].variants[].config.architecture'

# 2. Create the machine. --home-mount none is NON-NEGOTIABLE (default is rw,
#    which would give the guest full r/w on the mac home incl. ~/.ssh).
container machine create ghcr.io/boldsoftware/exeuntu:latest \
  --name iv-sandbox --cpus 4 --memory 8G --home-mount none

# 3. Boot + gate on systemd. container machine run REQUIRES A TTY — always wrap
#    it in `script`, or it errors "Operation not supported by device" / hangs.
script -q /dev/null container machine run -n iv-sandbox -- systemctl is-system-running < /dev/null
# gate: expect "running"
```

Run root commands in the guest via the same wrapper; for multi-line scripts,
base64-encode to avoid quoting/PTY mangling:

```bash
B64=$(base64 < my-script.sh | tr -d '\n')
script -q /dev/null container machine run -n iv-sandbox -- "echo $B64 | base64 -d | sudo bash" < /dev/null > out.log 2>&1
# strip CR / ANSI / the leading ^D from captured output:
tr -d '\r' < out.log | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' | grep -v '^\^D'
```

## Networking

- Machine networking: private `192.168.64.0/24`, gateway/DNS `192.168.64.1`,
  host↔guest reachable directly by IP, no port mapping. The host reaches guest
  services at the guest IP; the guest reaches host services at `192.168.64.1`.
- **Join the tailnet from inside the guest** (the VM is its own tailnet node —
  the same model as an exe.dev VM). Tailscale is preinstalled in exeuntu
  (service disabled). The Kata kernel **has `/dev/net/tun`**, so kernel
  networking works — userspace-networking is NOT required here.

```bash
# in guest, as root:
systemctl enable --now tailscaled
tailscale up --authkey=<tagged-key> --hostname=<name> --accept-dns
tailscale serve --bg http://127.0.0.1:<service-port>   # publishes https://<name>.<tailnet>
```

Mint the auth key on the host from the Tailscale OAuth client (see
`secrets.md`); only the one-use tagged key enters the guest. Note the OAuth
client must be permitted to mint the tag you request (tag:sandbox failed as
"not permitted"; tag:dev worked).

## Guest facts (exeuntu under machine mode)

- Login user is `exedev` (UID 1000); machine mode also creates your mac user in
  the guest. Do agent-facing setup under `/home/exedev`.
- `exe-setup.service` no-ops locally (`ConditionPathExists=/exe.dev/setup`, which
  the control plane would inject and does not exist locally). Correct behavior.
- `systemd-growfs-root.service` **fails** on the container-presented rootfs
  ("Online resizing not supported with sparse_super2"). Harmless; **mask it** to
  keep `systemctl is-system-running` = `running`.
- Shelley is **not in the image** — the image only carries the
  `exe.dev/install-shelley` label; the control plane installs it on real VMs.
  Install the arm64 release binary yourself (checksum-verify against the release
  `checksums.txt`), and drop in a unit override to run it locally (drop
  `-require-header X-Exedev-Userid`; point `-config` at a local shelley.json).

## Reboot resilience

A user LaunchAgent (RunAtLoad) boots the machine at login:

```
container system start && script -q /dev/null container machine run -n <name> true < /dev/null
```

Acceptance test (run twice): `sudo reboot`, then load the VM's tailnet URL from
a phone with no touch of the mini. On failure check, in order: (1) the App Data
Protection prompt (pending dialog blocks boot), (2) `container system stop &&
container system start` for post-reboot subnet/bridge desync.

## Known failure modes (in order to check)

1. **Boot/exec hangs → XPC timeout / "Operation not supported by device"** —
   pending App Data Protection prompt, or missing TTY. Grant the helper
   permission; always exec with `script -q /dev/null … < /dev/null`.
2. **First-ever `container` op hangs then dies** — known first-use race
   (apple/container #857); a daemon cycle + retry clears it.
3. **Subnet/bridge desync after macOS reboot** — `container system stop &&
container system start`.

## Fact-sheet corrections found in practice

- Guest kernel was **6.18.15**, not the expected Kata 6.12.x; and it **has
  `CONFIG_TUN`** built in (userspace-networking unnecessary).
- exeuntu ghcr image is **natively arm64** (no local Dockerfile rebuild).
- The macOS 26 boot hangs were **App Data Protection** prompts for the container
  helpers, not the Local Network permission.

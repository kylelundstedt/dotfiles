# exe.dev — our specifics

Vendor docs are canonical and versioned upstream: **<https://exe.dev/docs.md>**
(index) and `https://exe.dev/docs/<page>.md` for any page. exe.dev also ships an
official agent skill (`skill/SKILL.md` in their repo) which is deliberately thin
— quick reference plus a pointer to the docs index, so agents discover
progressively instead of carrying a copy.

**This file is not a copy of those docs.** It holds only what is specific to
this fleet, or non-obvious enough that rediscovering it costs an afternoon.

> Why it exists: a 295-line `exe-dev` skill was removed from this repo on
> 2026-06-11 (`c0c0553`) as not worth maintaining. Nothing preserved its
> still-true parts, and an unmanaged copy kept loading into agent sessions on
> `klundstedt-mini` for six weeks after the deletion — still describing an
> auto-provisioning hook that had been deliberately removed. Vendor detail
> rots; fleet-specific contracts belong in the repo that owns them.

## SSH discipline — the rule that actually bites

Both the `exe.dev` lobby and direct VM SSH (`*.exe.xyz`) silently drop inbound
TCP SYNs past an undocumented per-source-IP rate. The block lasts minutes and
looks exactly like a hung connection.

- **One SSH attempt at a time. Never parallel.** Enforced by a `PreToolUse`
  hook in `agents/.claude/settings.json` that denies a second concurrent
  `ssh … exe.(dev|xyz)`, and restated in the global agent instructions.
- After creating a VM: wait ~20s, then **one** attempt with
  `ConnectTimeout=30`. On failure wait 30–60s before one more.
- `~/.ssh/config` (written by `install.sh`) pins the exe.dev key and enables
  `ControlMaster`/`ControlPersist` for `exe.dev *.exe.xyz`, so many commands
  share one connection.
- **Once a VM is on the tailnet, use Tailscale SSH instead** (`ssh <vm>`, or
  `<vm>.dojo-sun.ts.net`). That is WireGuard, not exe.dev's edge, and is not
  rate-limited. Parallel tailnet SSH is fine.

## No auto-provisioning hook (deliberate, 2026-07)

`dev.exe new.setup-script` is **unset on purpose**. New VMs come up bare:
stock exeuntu ships `tailscaled` disabled, and dotfiles are not installed.

- `test-install.sh hook` (`test_no_hook`) asserts the key stays unset and fails
  if a hook reappears. exe.dev prints the literal `(not set)` with rc=0.
- Joining the tailnet is an on-demand, explicit step: the `join-tailnet` skill.
  Network identity is a decision, not a side effect of creating a VM.
- Provisioning the IV baseline is likewise explicit, via `iv-image`.

## Creating a VM

```bash
ssh exe.dev new --name=<vm> --tag=iv           # exeuntu, user exedev
ssh exe.dev rm <vm>                            # destroy
```

- **Names cannot end with `-<digits>`** (`test-123` is rejected, `test-abc`
  works). The name becomes the subdomain `https://<vm>.exe.xyz/`.
- `--tag=iv` attaches the IV-scoped integrations. It **no longer attaches
  `tailscale-api`** (changed 2026-07-28): that integration is tailnet
  administration and is now attached on demand by `join-tailnet` and detached
  again on exit. See [`exe-dev-remediation.md`](exe-dev-remediation.md).
- Create throwaway canaries on demand and delete them after validation; do not
  keep a persistent canary, and never author source commits on a VM
  (see "Repository authoring boundary" in `CLAUDE.md`).

## Reflection — a VM can describe itself

Every VM reaches `https://reflection.int.exe.xyz/` with no credentials
(attached `auto:all` by default). Use it instead of guessing what a VM has.

```bash
curl -s https://reflection.int.exe.xyz/              # available paths
curl -s https://reflection.int.exe.xyz/integrations  # name, type, comment, help
curl -s https://reflection.int.exe.xyz/tags
```

`/integrations` is the fastest way to answer "which repo can this VM clone?".
It is no longer the check to run before `join-tailnet` — the expected answer for
`tailscale-api` is now **not attached**, and the script attaches it itself.
Each entry's `help` field gives the literal command — clone URLs come back as
`https://github.int.exe.xyz/<org>/<repo>.git`.

Integration **comments carry provenance** and show up here, e.g. the
`tailscale-api` entry reads "Tailscale OAuth client (auth_keys+devices:core,
tag:dev) — U11 2026-07; creds in 1P: Tailscale OAuth Dev". Keep writing them
that way: it is the only place a VM can learn where its credentials came from.
Verified live on `iv-home`, 2026-07-22.

## Scoped HTTPS API tokens

`https://exe.dev/exec` takes SSH-signed bearer tokens (`exe0.<payload>.<sig>`)
whose payload is signed JSON with `cmds` (explicit allowlist — parent commands
do **not** grant subcommands), `exp`, `nbf`, and `ctx`. Rate limits are per SSH
key rather than the silent per-IP block, which makes this the right interface
for scripted or agent-driven lobby work. `ssh-keygen -Y sign` works with the
1Password agent given the public key file. Full recipe:
<https://exe.dev/docs/https-api.md>.

## Related

- `join-tailnet` skill — on-demand tailnet enrollment (verified 2026-07-22).
- `upgrade-vm` skill — re-provision at a newer `iv-image` commit.
- `agent_docs/exe-dev-web.md` — per-VM web service audit.
- `agent_docs/secrets.md` — integration scoping and tag conventions.

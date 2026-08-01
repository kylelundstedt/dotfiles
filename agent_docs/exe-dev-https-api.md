# exe.dev HTTPS API — evaluation for the provisioning workflows

> Analysis only, 2026-07-31. **No key was created and no workflow was
> changed.** The conclusion is that this belongs with the scheduled recreate
> cycle, not before it — see [Recommendation](#recommendation).

## What the API actually is

`POST https://exe.dev/exec` with the **same command string** you would type over
SSH in the body. JSON output is always on. One surface, two transports — you can
develop a call interactively over SSH and then ship it as an HTTPS request
unchanged.

Tokens are generated server-side:

```sh
ssh exe.dev ssh-key generate-api-key --label=NAME --cmds=CMD1,CMD2 --exp=30d
```

Docs: `ssh exe.dev doc https-api`, `… doc https-api-local-key`,
`… doc https-tokens-for-vms`.

### Token scoping is the useful part

`--cmds` restricts which commands a token may run. Two details that matter:

- The default set is **narrow and excludes what our automation uses**:
  `["help","ls","new","whoami","ssh-key list","share show","exe0-to-exe1","team","team members"]`
  — no `integrations`, no `rm`, no `rename`, no `stat`.
- **Subcommands must be listed explicitly.** Granting `"integrations"` does
  _not_ grant `"integrations attach"`. Spell out each one.

`exp` / `nbf` are supported and the docs recommend always setting `exp` (default
is "never").

## Call inventory (as of 2026-07-31)

| Workflow                     | Control-plane calls (`ssh exe.dev`)                                            | Must stay SSH                   |
| ---------------------------- | ------------------------------------------------------------------------------ | ------------------------------- |
| `new-dev-vm --recreate`      | 5 — `ls`×3, `integrations list`, `new`                                         | provision, overlay, repo clones |
| `join-tailnet`               | 3 — `integrations list`, `attach`, `detach`                                    | `tailscale up` over the edge    |
| `retire-vm`                  | ~12 — `ls`, `integrations list`, attach+detach per integration, `rm`, `rename` | hostname reset over the edge    |
| `recreate-fleet --preflight` | ~5 per VM                                                                      | per-VM git audit (over tailnet) |

**≈20 control-plane calls per VM cycle; ~120 for a six-VM pass.**

## It does NOT solve the lockout problem

This was the original motivation and it does not hold up.

The lockouts we hit came from **`*.exe.xyz` edge** connections — per-VM shells,
which must stay SSH — not from the lobby. And the lobby is already multiplexed:
`ControlMaster` is set for `Host exe.dev *.exe.xyz` on the Mac, so those ~120
calls ride **one** TCP connection and generate no repeated SYNs. Moving them to
HTTPS removes SSH sessions that were never the problem.

## The scoping benefit is smaller than it first appears

A scoped token restricts what the **token** can do, not what the **script** can
do. `new-dev-vm` needs `new`; `retire-vm` needs `rm` and `rename`. Both keep
full-authority SSH regardless and can fall back to it at any line. Converting
their read calls to a scoped token is therefore **mostly presentational** — the
same script on the same Mac still holds full account authority.

Scoping is only real in a context with **no SSH fallback**.

## Recommendation

**Adopt it as the credential for the scheduled recreate cycle, not for the
interactive scripts.** An unattended cron run is exactly where a credential that
cannot `rm` a VM or `share set-public` earns its keep, because nobody is
watching. Interactive work keeps the SSH key.

Design, when that lands:

- 1Password item **"exe.dev API"** (Private vault); token in the credential field.
- `--label=iv-automation --exp=90d`, `--cmds` limited to
  `ls, stat, integrations list, integrations attach, integrations detach`.
  Deliberately **no** `new`, `rm`, `rename`, `share`, `resize`, `domain`.
- Materialized at runtime only:
  `timeout 10 op read "op://Private/exe.dev API/credential"` into a shell
  variable. Never written to disk, never echoed.
- Fetched once per run by a shared helper, not per call.
- Expiry tracked alongside the existing key-expiry check in `launchd/`.

Staged rewire, each step independently revertable:

1. Read-only calls (`ls`, `stat`, `integrations list`) with SSH fallback.
2. `integrations attach`/`detach` in `join-tailnet` and `retire-vm`'s move loop.
3. `new`, `rm`, `rename` stay on SSH permanently — destructive operations should
   require the full-authority path.

## Two constraints that cost real digging

**Local token signing is unusable for us.** `ssh-keygen -Y sign` requires a
private key **file** (`-f path/to/key`). Our exe.dev key lives only in the
1Password agent, and the docs' own workaround is to use the private key file
directly. Exporting it to disk is exactly what our hygiene rules forbid, so:
**server-generated tokens only.**

**It does not survive a locked 1Password.** `op read` needs 1Password unlocked
just as `ssh-add -T` does, so this converts "agent cannot sign" into "op cannot
read" — the same failure with a different message. It is _not_ a fix for the
lock-outs that stalled work twice on 2026-07-29/30. Only a service-account
token would change that, which is a separate decision.

## Open question

Whether the HTTPS endpoint has its own rate limits is **not documented and not
tested**. Probe with a handful of calls before relying on it for parallelism —
parallel _management_ calls are one of the two gates on parallel recreates (the
other is the unlocked read-modify-write of the AgentsView collector TOML, which
this does not touch).

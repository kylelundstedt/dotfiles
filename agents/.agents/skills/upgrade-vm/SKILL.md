---
name: upgrade-vm
description: Reprovision an exe.dev VM onto a new iv-image version without getting a -1 tailnet name. Use when moving a running VM to a newer image (e.g. iv-image:2 → a later build) — exe.dev only applies an image at creation, so this destroys + recreates the VM with the same name, deleting the stale Tailscale node first so the new VM keeps the clean name.
---

# upgrade-vm

exe.dev applies an image **only at VM creation** — there is no in-place image
upgrade. So upgrading a VM to a newer image means destroy + recreate with the
same name. If the old ephemeral Tailscale node still holds the name when the new
VM joins, the new VM lands as `<name>-1`. This skill prevents that.

## Run it (from a control node)

```bash
~/.agents/skills/upgrade-vm/upgrade-vm.sh <vm> [image]
```

- `<vm>` — the exe.dev VM name to reprovision.
- `[image]` — defaults to `iv-registry.exe.xyz:5000/iv-image:2`.

**Run this from a control node**, not the VM being upgraded — a machine that can
reach `https://tailscale-api.int.exe.xyz` (an exe.dev VM with the `tailscale-api`
integration attached, e.g. `iv-registry`). The device-delete authority lives
here, deliberately not on disposable VMs.

## What it does

1. `ssh exe.dev rm <vm>` — destroy the old VM (no-op if it doesn't exist).
2. Delete the stale tailnet node(s) whose hostname is `<vm>` (this also catches a
   prior `<vm>-1`), polling `/devices` until the name clears — deletion needs a
   moment to propagate. Aborts if it can't clear, rather than create a `-1`.
3. `ssh exe.dev new --name=<vm> --tag=iv --image=<image>` — recreate.
4. Call the `join-tailnet` skill — the new VM now claims the clean `<vm>` name.

## Why the delete lives here, not on the VM

iv-image `>= 2.0.0` intentionally removed device-delete authority from VMs (an
ephemeral VM holding API delete rights is a bigger blast radius than it needs).
This skill keeps that property: the stale-node cleanup runs from a trusted
control node that already holds tailnet/proxy access, so the new VM never needs
delete rights to get a clean name.

## Overrides

- `IV_VM_IMAGE` — default image when `[image]` is omitted.
- `IV_VM_TAG` — VM tag (default `iv`).
- `IV_TAILSCALE_API_URL` — proxy base URL.

## Notes

- This destroys the VM's local disk. Anything not persisted off-box is lost —
  this reprovisions, it does not migrate state.
- If the join step fails (VM slow to become reachable), re-run `join-tailnet <vm>`
  by hand — one attempt at a time (`*.exe.xyz` rate-limits SYN bursts).

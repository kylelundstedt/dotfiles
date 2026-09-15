# LM Studio for the fleet — the `iv-llm-relay` bridge

> Status: **WORKING 2026-09-15.** Verified end to end on `iv-cli`: exe.dev
> discovers the model, Shelley lists `qwen/qwen3.6-35b-a3b@lmstudio`, and a
> chat completed through relay → mini → LM Studio (6.4k-token Shelley system
> prompt, ~29 s on the 35B-A3B model). Attached `auto:all`.

## What it is

Local models served by LM Studio on `klundstedt-mini` (and, from ~2026-10, the
Studio Ultra) appear in every exe.dev VM's Shelley model picker through one
exe.dev **llm integration** (`lmstudio`), with no per-VM configuration and no
secret on any VM. The bridge is a dedicated exeslim VM, `iv-llm-relay`, running
nginx.

```
Shelley on any VM
  → https://lmstudio.int.exe.xyz          (exe.dev llm integration, auto-discovered
                                            by Shelley via reflection)
  → https://iv-llm-relay.exe.xyz/mini/v1  (public port 8000; exe.dev injects
                                            X-LLM-Relay-Key)
  → nginx on iv-llm-relay                 (403 unless the key matches;
                                            rewrites /mini/… → /lmstudio/…)
  → https://klundstedt-mini.dojo-sun.ts.net/lmstudio/…   (tailnet; tag:relay → mini tcp:443)
  → tailscale serve on the mini            (strips /lmstudio)
  → LM Studio 127.0.0.1:1234               (OpenAI-compatible; Responses API used)
```

## Why this shape (measured 2026-09-15)

- **Why an llm integration and not per-VM Shelley custom models.** Shelley
  discovers every attached `llm` integration and lists its models with zero VM
  config; custom models would be one SQLite row per VM (they exist —
  `/api/custom-models` over the unix socket — and remain the fallback).
- **Why a relay at all.** exe.dev's edge makes the outbound calls and is not on
  the tailnet. It rejects tailnet hosts outright (`host
"klundstedt-mini.dojo-sun.ts.net" is not allowed`) and bare IPs; only a public
  HTTPS hostname is accepted.
- **Why not the existing `iv-personal-mcp-relay`.** That relay works for hub-mcp
  only because hub-mcp uses a `--peer` http-proxy, and its port is **private**.
  The llm integration's custom provider has no peer mode (the `--peer` flag is
  accepted and silently ignored; the UI offers only "Custom headers"), so
  exe.dev's discovery fetch hit the private-port login redirect and the model
  list stayed empty — verified: no request ever reached that relay's nginx, and
  the same happened with a public no-auth provider (OpenRouter) as a control.
  Making that VM's port public would also expose the personal archive behind
  hub-mcp. Hence a dedicated relay with a public port and a header gate.
- **Why path mounts.** The relay routes by path (`/mini/`, later `/ultra/`), so
  one integration and one relay cover every LM Studio host. On the mini, LM
  Studio is mounted at `/lmstudio` on the existing `:443` serve listener
  rather than a new port because `tcp:443` is the one door the tailnet policy
  already opens to `tag:relay` (the `:8443` door from earlier the same day is
  kept for Kyle's own devices only).
- **Why `openai_responses`.** exe.dev custom providers support only
  `openai_responses` and `anthropic_messages`. LM Studio serves
  `/v1/responses` (verified with a reasoning model), so no translation layer.
- **Discovery is exe.dev's, not ours.** The provider's "Models" field is a
  glob **filter** over what exe.dev discovers from `<base>/models`; setting an
  explicit ID does not bypass discovery (verified: list stayed empty with
  `qwen/qwen3.6-35b-a3b` saved). So the relay path must work before anything
  shows up. Set the filter to the chat models only — LM Studio's `/v1/models`
  also lists every loaded embedding instance (`text-embedding-nomic-…:2..5`).

## Pieces

| Piece           | Where                                                                                                                                                         |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Relay VM        | `iv-llm-relay` (exe.dev, `ghcr.io/kylelundstedt/exeslim:2026-08-28.24.1`, nginx-light)                                                                        |
| nginx config    | `/etc/nginx/sites-enabled/relay` on the VM (root 0600; holds the key)                                                                                         |
| Shared key      | 1Password Employee → "LLM relay header key (iv-llm-relay)"                                                                                                    |
| exe.dev port    | `share port iv-llm-relay 8000`, `share set-public iv-llm-relay`                                                                                               |
| llm integration | `lmstudio`: custom provider `lmstudio` = `https://iv-llm-relay.exe.xyz/mini/v1`, API `openai_responses`, header `X-LLM-Relay-Key`; managed providers disabled |
| Mini serve door | `tailscale serve --bg --set-path=/lmstudio http://127.0.0.1:1234` (in tailscaled state)                                                                       |
| Tailnet         | relay joined via `join-tailnet`; needs **`tag:relay`** (admin console) for mini `tcp:443`                                                                     |

nginx gate, in words: `allow 127.0.0.1; allow 10.42.0.0/16; deny all` (only the
exe.dev proxy path and loopback), then per host `location /<host>/ { if
($http_x_llm_relay_key != "<key>") { return 403; } rewrite ^/<host>/(.*)$
/lmstudio/$1 break; proxy_pass https://<host>.dojo-sun.ts.net; … }` with SNI and
Host set to the tailnet name, `resolver 100.100.100.100`, 600 s read timeout,
buffering off. Unknown paths 404. Note `proxy_pass` with a variable does not
append the request URI — the `rewrite … break` is what carries the path.

## Runbooks

**Add the Studio Ultra.** On the Ultra: `tailscale serve --bg
--set-path=/lmstudio http://127.0.0.1:1234` and make sure the policy lets
`tag:relay` reach it on `tcp:443`. In the repo: copy the `/mini/` location in
`provisioning/iv-llm-relay/relay.nginx` to `/ultra/` with the Ultra's tailnet
name, then `provisioning/iv-llm-relay/deploy.sh` (idempotent; reloads nginx
only on change and checks the 403 gate).
On exe.dev: `integrations edit lmstudio --custom-provider=lmstudio-ultra=https://iv-llm-relay.exe.xyz/ultra/v1 --custom-provider-api=openai_responses --header=X-LLM-Relay-Key:<key>`
(check whether `edit` keeps the first provider; if not, re-add both), then set
that provider's Models filter in the UI. With two providers the models carry
the provider id, so both hosts' models are distinguishable in the picker.

**Rotate the key.** `openssl rand -hex 32`; update the 1Password item; run
`provisioning/iv-llm-relay/deploy.sh` (renders the new key into nginx);
`integrations edit lmstudio --header=X-LLM-Relay-Key:<new>` (replaces all
headers). Order does not matter beyond a few seconds of 403s.

**Check the chain from the mini.**

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://iv-llm-relay.exe.xyz/mini/v1/models            # 403: gate works
curl -s -H "X-LLM-Relay-Key: $(op read 'op://Employee/LLM relay header key (iv-llm-relay)/credential')" \
  https://iv-llm-relay.exe.xyz/mini/v1/models | jq '.data[].id'                                    # model list: tailnet hop works
ssh iv-cli 'curl -s https://lmstudio.int.exe.xyz/models.json | jq ".models"'                       # exe.dev discovery
ssh iv-cli 'shelley models | grep -i lmstudio'                                                     # Shelley sees it
```

**Rebuild the relay.** `ssh exe.dev new --name=iv-llm-relay --image=ghcr.io/kylelundstedt/exeslim:2026-08-28.24.1 --tag=tailnet`,
`join-tailnet.sh iv-llm-relay`, `provisioning/iv-llm-relay/deploy.sh` (installs
nginx-light if missing, renders the key from 1Password), `share port … 8000`

- `share set-public`, add `tag:relay` in the admin console. Tailscale SSH does
  not serve SFTP, so the deploy script uses the `.exe.xyz` endpoint; over the
  tailnet copy files with `ssh … 'cat > /tmp/x' < x`, not `scp`.

## Threat model, briefly

The public port accepts anyone, but nginx answers 403 to everything without
the key and 404 off the known paths. The key is at exe.dev (server side,
injected at the edge) and in one root-owned file on the relay — a compromise
of the relay yields inference on the mini's local models, nothing else. LM
Studio itself has no auth; it never listens beyond loopback. The relay holds
no other credential and no state.

## Open

- **Models filter** for the mini provider is currently the single ID
  `qwen/qwen3.6-35b-a3b` (set in the UI during bring-up; the CLI has no flag for
  it). Widen to `qwen/*` or an explicit list — not `*`, which drags every loaded
  embedding instance into the picker.
- **Running Shelley servers do not re-discover integrations on their own.**
  A server started before the attach says "unsupported model" until the
  catalog is refreshed. Non-disruptive fleet refresh (run from `iv-provision`
  or the mini; tailnet SSH, one VM at a time):

  ```bash
  for vm in $(tailscale status --json | jq -r '.Peer[] | select(.OS=="linux" and .Online) | .HostName'); do
    printf '%-26s ' "$vm"
    ssh -o ConnectTimeout=10 -o BatchMode=yes "exedev@$vm" \
      'test -S ~/.config/shelley/shelley.sock && curl -s -m 20 -X POST --unix-socket ~/.config/shelley/shelley.sock http://shelley/api/models/refresh >/dev/null && echo refreshed || echo "no shelley"'
  done
  ```

  Done 2026-09-15 after the `auto:all` attach: 15 VMs refreshed, 4 correctly
  reported no Shelley (the three relays/appliances and `rss-feed`). `shelley
models` (the CLI) always runs discovery fresh, so it is not a proof that the
  running server sees the model — check `/api/models` over the socket.

- **`tag:prod` on the relay node.** The join helper requested `tag:dev`
  (`join-tailnet.sh` line ~149, `"tags":["tag:dev"]`) and the node came up
  `tag:prod`; `rss-feed` is the only other `tag:prod` node. The 1Password
  "Tailscale OAuth" client is documented `tag:dev`-only, so the credential
  exe.dev's `api-tailscale` integration injects is probably a different client,
  or that client's tag list changed. Check admin console → Settings → OAuth
  clients before the next join. Harmless for the relay: `tag:relay` carries the
  mini grant and SSH from the mini works.
- The personal-mcp relay's nginx config is now versioned too
  (`provisioning/iv-personal-mcp-relay/`), same template + `deploy.sh` shape,
  no secret to render.
- Tailnet policy is still admin-console-only (the OAuth client in 1Password is
  `auth_keys`-scoped), so `tag:relay` on a rebuilt relay is a manual step.
- Coverage: `iv-llm-relay` is a bare appliance and is listed in
  `provisioning/agentsview-coverage-exclude.txt`.

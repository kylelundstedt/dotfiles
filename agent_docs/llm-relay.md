# LM Studio for the fleet — the `iv-llm-relay` bridge

> Status: **BUILT 2026-09-15, awaiting one admin-console step** (add
> `tag:relay` to the `iv-llm-relay` node; see "Open"). Until then exe.dev's
> model discovery fails at the tailnet hop and Shelley shows no LM Studio
> models.

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
`tag:relay` reach it on `tcp:443`. On the relay: copy the `/mini/` location to
`/ultra/` with the Ultra's tailnet name; `nginx -t && systemctl reload nginx`.
On exe.dev: `integrations edit lmstudio --custom-provider=lmstudio-ultra=https://iv-llm-relay.exe.xyz/ultra/v1 --custom-provider-api=openai_responses --header=X-LLM-Relay-Key:<key>`
(check whether `edit` keeps the first provider; if not, re-add both), then set
that provider's Models filter in the UI. With two providers the models carry
the provider id, so both hosts' models are distinguishable in the picker.

**Rotate the key.** `openssl rand -hex 32`; update the 1Password item; edit the
key in `/etc/nginx/sites-enabled/relay` and reload nginx; `integrations edit
lmstudio --header=X-LLM-Relay-Key:<new>` (replaces all headers). Order does
not matter beyond a few seconds of 403s.

**Check the chain from the mini.**

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://iv-llm-relay.exe.xyz/mini/v1/models            # 403: gate works
curl -s -H "X-LLM-Relay-Key: $(op read 'op://Employee/LLM relay header key (iv-llm-relay)/credential')" \
  https://iv-llm-relay.exe.xyz/mini/v1/models | jq '.data[].id'                                    # model list: tailnet hop works
ssh iv-cli 'curl -s https://lmstudio.int.exe.xyz/models.json | jq ".models"'                       # exe.dev discovery
ssh iv-cli 'shelley models | grep -i lmstudio'                                                     # Shelley sees it
```

**Rebuild the relay.** `ssh exe.dev new --name=iv-llm-relay --image=ghcr.io/kylelundstedt/exeslim:2026-08-28.24.1 --tag=tailnet`,
`apt-get install nginx-light`, `join-tailnet.sh iv-llm-relay`, install the
nginx file (key from 1Password), `share port … 8000` + `share set-public`,
add `tag:relay` in the admin console. Tailscale SSH does not serve SFTP, so
copy files with `ssh … 'cat > /tmp/x' < x`, not `scp`.

## Threat model, briefly

The public port accepts anyone, but nginx answers 403 to everything without
the key and 404 off the known paths. The key is at exe.dev (server side,
injected at the edge) and in one root-owned file on the relay — a compromise
of the relay yields inference on the mini's local models, nothing else. LM
Studio itself has no auth; it never listens beyond loopback. The relay holds
no other credential and no state.

## Open

- **`tag:relay` on `iv-llm-relay`** — admin console → Machines → iv-llm-relay
  → Edit ACL tags. The node also came up as `tag:prod` rather than the
  `tag:dev` the join helper requests (unexplained; the OAuth client is
  documented as `tag:dev`-only) — fix in the same edit. Until this is done the
  relay's upstream hop times out and discovery stays empty.
- Fleet rollout after verification on `iv-cli`: `integrations attach lmstudio auto:all`
  (matches the default `llm` integration's scope).
- Models filter for the mini provider: `qwen/*` or an explicit list, not `*`.
- Coverage: `iv-llm-relay` is a bare appliance and is listed in
  `provisioning/agentsview-coverage-exclude.txt`.

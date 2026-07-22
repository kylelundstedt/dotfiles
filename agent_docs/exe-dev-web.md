# exe.dev web endpoints

Point-in-time fleet audit and the checks needed to distinguish an exe.dev proxy
failure from an application failure. The authoritative VM inventory is
`ssh exe.dev ls --json`; Tailscale is only a connectivity cross-check.

## Endpoint model

Each VM has separate web surfaces:

- `https://<vm>.exe.xyz` proxies the VM's configured application port (currently
  `8000` fleet-wide). A running VM does **not** imply that anything listens on
  that port.
- `https://<vm>.shelley.exe.xyz` is Shelley's UI. Shelley listens locally on
  `127.0.0.1:9999`; it is independent of the application proxy.
- Additional ports `3000..9999` are separately proxied for authenticated users.

Private application proxies redirect unauthenticated requests to exe.dev login.
That redirect proves only that the edge route exists. To test the upstream,
use an authenticated browser or a short-lived VM-scoped token, then correlate
with `ss -ltnp`, `curl 127.0.0.1:<port>`, and both system and user systemd units.

## Audit — 2026-07-19

All eight account VMs were `running`, tailnet-online, and reachable over SSH.
All eight local Shelley endpoints returned HTTP 200 (`Shelley Agent`).

| VM                    | App proxy                      | Intended state / finding                                                                                                                                                                                                                    |
| --------------------- | ------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `kgl-dotfiles`        | **Retired 2026-07-22**         | At audit time it served a healthy private Quarto preview and Linux canary. Its work and Shelley database were preserved on `klundstedt-mini` before the VM was deleted.                                                                     |
| `iv-gitlake`          | **200** (`GitLake`)            | Healthy private site. Enabled lingering user unit `docsite.service` serves `~/gitlake/_site` on `0.0.0.0:8000`.                                                                                                                             |
| `iv-home`             | **503 by design**              | Healthy closed-door service, intentionally tailnet-only. `ivhome.service` binds only the Tailscale IP on `8000`; its unit explicitly forbids `0.0.0.0` so the exe.dev proxy cannot reach it.                                                |
| `rss-feed`            | **200** (`RSS Feed Service`)   | Healthy public Go service. System unit `srv.service` is enabled with restart policy; healthcheck timer is active.                                                                                                                           |
| `kgl-thoughts`        | **200** (`Kyle Lundstedt`)     | Healthy public nginx static site. Both custom domains, `lundstedt.us` and `www.lundstedt.us`, also returned 200.                                                                                                                            |
| `iv-docs`             | **200** (`IndustryVault – IV`) | Healthy private site. Enabled lingering user unit `docsite.service` serves `~/iv-docs/_site` on `0.0.0.0:8000`. The redundant Ubuntu `ssh.service`/`ssh.socket` pair is masked; exe.dev's own `/exe.dev/bin/sshd` continues to own port 22. |
| `iv-ave-adapters`     | **200** (`AVE Adapters`)       | Healthy private Quarto site. The repository now commits `_quarto.yml` and `index.qmd`; enabled nginx serves the rendered `_site` on `0.0.0.0:8000`.                                                                                         |
| `iv-gitlake-examples` | **200** (`GitLake Examples`)   | Healthy private site. Enabled lingering user unit `docsite.service` serves `~/gitlake-examples/_site` on `0.0.0.0:8000`.                                                                                                                    |

The private proxy results above were verified through short-lived, five-minute
VM-scoped tokens rather than inferred from login redirects. No token was saved.

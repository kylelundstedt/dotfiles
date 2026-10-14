# On-demand UniFi administration

`unifi-session` is a human-run Codex launcher for occasional administration from
the mini. No container, scheduled agent, credential broker, or oMLX migration is
required. This script belongs in dotfiles because it is personal workstation
glue, not an iv-provision fleet service.

## Install on the mini

After this change is merged, in the mini's Terminal:

```bash
git -C ~/dotfiles pull --ff-only
stow --dir="$HOME/dotfiles" --no-folding -R -t "$HOME" maint
unifi-session
```

The existing installer already stows `maint`; no full `install.sh` run is
needed. Alternatively, run `~/dotfiles/maint/.local/bin/unifi-session` directly.
Do not source the script. It requires Bash 3.2+ and an already installed,
logged-in Codex CLI with `--no-daemon` support.

## Each session

1. Sign into the UDM locally. In the Network application's **Integrations**
   section, create a new API key. Use narrow permissions and an expiration if
   the installed controller offers them; neither is assumed. Leave the key
   management page open.
2. Run `unifi-session`. Enter the UDM's actual LAN IP or hostname, then paste
   the key at the hidden terminal prompt. Nothing appearing while you paste is
   normal. Do not paste it into Codex chat.
3. Codex starts in `~/unifi-admin`. Its initial task is to check credential
   availability without printing it, then list sites and devices using official
   local API read endpoints. Review permission requests before approving them.
4. For changes, require a specific plan, backup/recovery prerequisites, and
   rollback procedure first. For a firm human gate without extra infrastructure,
   run reviewed write commands yourself.
5. Exit Codex and **delete/revoke the key in UniFi**. The launcher reminds you;
   it does not revoke the key automatically. Clear your clipboard if it still
   holds the key.

To skip the address prompt, supply a non-secret HTTPS origin:

```bash
unifi-session https://udm.example.test
```

Replace that example with your actual console hostname. IPv4, bracketed IPv6,
and an optional port are accepted; HTTP, embedded credentials, paths, and query
strings are not. The launcher itself makes **no UniFi requests**, so it cannot
verify connectivity, the certificate, or the key.

## What the launcher does

- Creates `~/unifi-admin` with owner-only access and seeds a generic `AGENTS.md`
  only if absent. Existing instructions are not overwritten. A symlinked
  workspace or instructions file is rejected.
- Reads the key silently from an interactive terminal. No secret is put in the
  launcher's arguments, initial prompt, instructions, or a credential file.
  Shell tracing is disabled before key entry. Terminal echo is disabled before
  displaying the key prompt and the original terminal settings are restored on
  success, cancellation, and error, including on macOS's Bash 3.2.
- Supplies `UNIFI_URL` and `UNIFI_API_KEY` through the Codex process environment.
  A session-only shell-environment allowlist forwards these and basic OS
  variables to tools, rather than forwarding every inherited token.
- Uses `--no-daemon` to avoid putting the credential in a shared Codex server.
  Disables both shell-snapshot features (which can persist allowed exports) and
  login-shell execution for this run. Existing provider, login, and model
  settings still apply, including Aperture.
- Starts with the filesystem `read-only` sandbox and `on-request` approvals.
  Selects the human approval reviewer explicitly rather than inheriting an
  automatic reviewer. It does not enable unrestricted access or bypass approvals.
- Preserves Codex's exit status and reminds you to revoke after normal exit,
  errors, and handled interruption. A killed terminal, power failure, or
  `SIGKILL` can prevent the reminder; revocation is still your responsibility.
  A signal sent only to the launcher's PID is deferred while Codex runs and
  does not stop that child. Exit Codex or use terminal Ctrl-C, rather than
  treating termination of the wrapper as termination of credential access.

## What this does not guarantee

**This is credential handoff, not credential isolation.** Codex and any tools
given the environment can read or disclose the key. Its filesystem sandbox is
not a read-only UniFi API permission. `on-request` does not require approval for
every command, and instructions are not a technical API allowlist.

The launcher does not intentionally persist the secret, but the OS, Codex,
hooks, integrations, and approved tools have their own storage and logging
behavior. Do not assume the key can never reach disk or a transcript. Never
dump the environment, use shell tracing, or enable verbose HTTP headers.
The launcher does not disable your existing hooks or MCP integrations.

Network data returned to a remote model leaves the mini. Local execution is
not local inference. Keep backups and private reports out of the dotfiles
repository and retain a local recovery procedure that needs neither an LLM nor
internet access.

## Troubleshooting

- **Codex not installed or missing `--no-daemon`:** install/update Codex, sign
  in normally, then retry. Do not weaken the launcher's isolation flags.
- **Credential unavailable to tools:** stop. Check the installed Codex version
  and any managed environment policy without printing the value. No secret is
  written into `config.toml` to work around a denial. Do not define `UNIFI_URL`
  or `UNIFI_API_KEY` in an existing `shell_environment_policy.set`: such entries
  override the fresh environment values. Other configured `set` entries outside
  the launcher's allowlist are filtered out.
- **Certificate verification failure:** establish trust for the UDM's actual
  certificate and use a matching hostname/address. Do not default to `curl -k`.
- **Workspace error:** inspect `~/unifi-admin`; do not replace somebody else's
  directory or symlink blindly.
- **Cancel:** Ctrl-C at either prompt, or exit Codex. Revoke the key even if the
  session never completed. Restarting/resuming later needs a fresh handoff.

## Tests and qualification

```bash
bash -n maint/.local/bin/unifi-session
shellcheck maint/.local/bin/unifi-session
uv run --no-project python -m unittest -v maint/test_unifi_session.py
```

The PTY tests use a fake Codex and synthetic credentials. They exercise hidden
input, credential delivery, cancellation, failure status, redaction, workspace
permissions, existing-file preservation, input validation, and noninteractive
refusal. They make no network/model calls. They do not establish live UniFi API
permissions or end-to-end behavior on the mini; those need an owner-supervised
first run.

## Primary references

- UniFi local key creation: `https://developer.ui.com/network/v10.6.106/gettingstarted`
- Codex shell environment policy: `https://developers.openai.com/codex/config-advanced`
- Codex sandbox and approvals: `https://developers.openai.com/codex/agent-approvals-security`
- Codex snapshot behavior: `https://github.com/openai/codex/blob/rust-v0.162.1/codex-rs/core/src/shell_snapshot.rs`
- Codex config merging: `https://github.com/openai/codex/blob/rust-v0.162.1/codex-rs/config/src/merge.rs`
- The installed `codex --help` documents `--no-daemon`; checked with CLI 0.162.1.

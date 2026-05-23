# Linux

## Platform Notes

- Primary Linux target is exe.dev VMs running `boldsoftware/exeuntu` (Ubuntu 24.04 + kitchen-sink tools). See the `exe-dev` skill for VM lifecycle.
- Apple Containers and Sprites are alternative platforms, not actively maintained (see TODO.md).
- `install.sh` skips tools already present on the image (`need` checks) to avoid redundant downloads.
- Shell change targets zsh; in non-interactive mode it may be skipped without sudo/root.

## Testing on Linux

Use the included test script, which tests across Apple Container, Sprite, and exe.dev:

```bash
./test-install.sh
```

For a quick one-off Docker test:

```bash
docker run --rm -it ghcr.io/astral-sh/uv:python3.12-bookworm bash -c \
  "apt-get update && apt-get install -y sudo zsh && \
   curl -fsSL https://raw.githubusercontent.com/kylelundstedt/dotfiles/master/install.sh | bash; exec zsh -l"
```

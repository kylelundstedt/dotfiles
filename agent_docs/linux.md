# Linux

## Platform Notes

- Installer prefers native package managers (APT when available) for core CLI tools
- Homebrew on Linux is optional for core tools, but used for `--include-heavy` packages
- Shell change targets `/usr/bin/zsh`; in non-interactive mode it may be skipped without sudo/root
- Claude MCP wrapper scripts use 1Password secret references via `op run`

## Testing on Linux

To test the Linux installation path locally, you can use a one-off Docker container that mimics a fresh environment.

This command uses the official `uv` image (which has Python, Curl, and Git) but mimics a clean start by ensuring dependencies are installed before running the script:

```bash
docker run --rm -it ghcr.io/astral-sh/uv:python3.12-bookworm bash -c "apt-get update && apt-get install -y sudo zsh && curl -fsSL https://raw.githubusercontent.com/kylelundstedt/dotfiles/master/install.sh | bash; exec zsh -l"
```

Alternatively, you can use the included test script if you have OrbStack installed:

```bash
./test-linux.sh
```

This uses OrbStack's Linux VM to verify the installation works on Linux.

## OrbStack (Local Linux VMs on macOS)

[OrbStack](https://orbstack.dev/) provides fast, lightweight Linux VMs on macOS.

```bash
# Create a new Ubuntu VM
orb create ubuntu my-ubuntu

# Shell into the VM
orb -m my-ubuntu

# Run a command on the VM
orb -m my-ubuntu uname -a

# Bootstrap dotfiles on the VM
orb -m my-ubuntu bash -c "curl -fsSL https://raw.githubusercontent.com/kylelundstedt/dotfiles/master/install.sh | bash"

# List all VMs
orb list

# Delete a VM
orb delete my-ubuntu
```

## Fly.io Sprites (Cloud VMs)

[Sprites](https://fly.io/blog/design-and-implementation/) are lightweight, persistent cloud VMs from Fly.io that create in seconds.

```bash
# Login to Fly.io (first time only)
sprite login

# Create a new sprite
sprite create my-sprite

# Shell into an existing sprite
sprite console -s my-sprite

# Run a command on a sprite
sprite exec -s my-sprite uname -a

# Bootstrap dotfiles on a sprite
sprite exec -s my-sprite bash -c "curl -fsSL https://raw.githubusercontent.com/kylelundstedt/dotfiles/master/install.sh | bash"

# List all sprites
sprite list

# Destroy a sprite
sprite destroy -s my-sprite
```

Sprites automatically sleep when inactive and wake instantly on connection, keeping costs minimal.

## Cloud-Init (VM Bootstrap)

If your VM provider supports cloud-init, you can pass a user-data config that installs prerequisites and runs `install.sh --no-prompt` to bootstrap the standard CLI toolchain automatically.

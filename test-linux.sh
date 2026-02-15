#!/bin/bash
# Test script for install.sh on Linux
# Usage: ./test-linux.sh
#
# This uses OrbStack's native Linux VM to test the install script.
# OrbStack automatically translates macOS paths to Linux paths.
#
# Note: Some operations may behave differently in a VM vs real Linux:
# - chsh (shell change) - may require user interaction
# - Homebrew installation - will install if not present

set -e

DOTFILES_DIR="$(pwd)"

if ! command -v orbctl >/dev/null 2>&1; then
    echo "Error: orbctl not found. This script requires OrbStack."
    echo ""
    echo "Alternative (Docker):"
    echo "  docker run --rm -it ghcr.io/astral-sh/uv:python3.12-bookworm bash -c \"apt-get update && apt-get install -y sudo zsh && curl -fsSL https://raw.githubusercontent.com/kylelundstedt/dotfiles/master/install.sh | bash; exec zsh -l\""
    exit 1
fi

echo "Testing install.sh on OrbStack Linux VM..."
echo "Dotfiles directory: $DOTFILES_DIR"
echo "Note: This will install Homebrew (Linuxbrew) and run the full install script."
echo ""

# Ensure prerequisites are installed on the Linux VM
echo "Installing prerequisites..."
orbctl run bash -c "
    export DEBIAN_FRONTEND=noninteractive && \
    sudo apt-get update -qq && \
    sudo apt-get install -y -qq git curl sudo bash ca-certificates build-essential 2>/dev/null || true
"

# Run the install script on the Linux VM
# OrbStack automatically translates the macOS path to the Linux equivalent
echo ""
echo "Running install.sh on Linux VM..."
orbctl run -w "$DOTFILES_DIR" bash -c "
    cd '$DOTFILES_DIR' && \
    bash install.sh
"

echo ""
echo "Test complete! Check the output above for any errors."

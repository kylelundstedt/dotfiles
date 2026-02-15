#!/bin/bash

# Ensure uv is available
if ! command -v uv &> /dev/null; then
    echo "uv is not installed. Please install it first using Homebrew: brew install uv"
    exit 1
fi

# Create a per-project venv in the python/ directory
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_DIR="$PROJECT_DIR/.venv"
uv venv "$VENV_DIR" --python=3.12

# Install project dependencies using uv (reads pyproject.toml)
(
  cd "$PROJECT_DIR" || exit 1
  uv sync
)

echo "Python packages have been installed successfully in $VENV_DIR"

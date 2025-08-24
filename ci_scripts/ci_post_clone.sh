#!/bin/bash
set -euo pipefail

# Ensure Homebrew and Bun are available for Xcode Cloud builds
export PATH="$HOME/.bun/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

if command -v bun >/dev/null 2>&1; then
  echo "bun already installed: $(bun --version)"
else
  if ! command -v brew >/dev/null 2>&1; then
    echo "Homebrew not available; cannot install bun" >&2
    exit 1
  fi
  brew update
  brew install bun || brew install oven-sh/bun/bun
fi

bun --version



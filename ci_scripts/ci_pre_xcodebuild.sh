#!/bin/bash
set -euo pipefail

# Ensure tools are on PATH for Xcode Cloud build phases
export PATH="$HOME/.bun/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

# Resolve repo root in Xcode Cloud or local
REPO_ROOT="${CI_WORKSPACE:-$(cd "$(dirname "$0")/.."; pwd)}"

echo "[pre-xcodebuild] Repo root: $REPO_ROOT"

# Make sure the dist folder exists so Xcode picks it up as a resource folder
mkdir -p "$REPO_ROOT/safari/Resources/dist"

if ! command -v bun >/dev/null 2>&1; then
  echo "[pre-xcodebuild] bun not found. Attempting to install via Homebrew..."
  if command -v brew >/dev/null 2>&1; then
    brew install bun || brew install oven-sh/bun/bun
  else
    echo "[pre-xcodebuild] Homebrew not available; cannot install bun" >&2
    exit 1
  fi
fi

echo "[pre-xcodebuild] bun version: $(bun --version)"

echo "[pre-xcodebuild] Installing web-ui dependencies..."
cd "$REPO_ROOT/web-ui"
bun install --no-progress

echo "[pre-xcodebuild] Building web-ui (content.iife.js)..."
bun run build

echo "[pre-xcodebuild] Build outputs:"
ls -lah "$REPO_ROOT/safari/Resources/dist" || true

echo "[pre-xcodebuild] Done."



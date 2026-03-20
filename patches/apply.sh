#!/usr/bin/env bash
# Apply caching + vim patches to opencode source
# Usage: ./apply.sh <path-to-opencode-source>
#
# Fetches caching.patch from opencode-cached (never duplicated here),
# then applies local vim.patch on top.

set -euo pipefail

if [ $# -ne 1 ]; then
  echo "Error: Missing argument"
  echo "Usage: $0 <path-to-opencode-source>"
  exit 1
fi

SOURCE_DIR="$1"
SCRIPT_DIR="$(dirname "$0")"
VIM_PATCH="$SCRIPT_DIR/vim.patch"
CACHING_PATCH_URL="https://raw.githubusercontent.com/johnnymo87/opencode-cached/main/patches/caching.patch"

if [ ! -d "$SOURCE_DIR" ]; then
  echo "Error: Source directory not found: $SOURCE_DIR"
  exit 1
fi

if [ ! -f "$VIM_PATCH" ]; then
  echo "Error: Vim patch not found: $VIM_PATCH"
  exit 1
fi

cd "$SOURCE_DIR"

# --- Patch 1: Caching (fetched from opencode-cached) ---

echo "Fetching caching.patch from opencode-cached..."
CACHING_PATCH="/tmp/caching-$$.patch"
if ! curl -sfL "$CACHING_PATCH_URL" -o "$CACHING_PATCH"; then
  echo ""
  echo "❌ FAILED TO FETCH CACHING PATCH"
  echo "URL: $CACHING_PATCH_URL"
  echo ""
  echo "Check that opencode-cached repo is accessible and patches/caching.patch exists on main."
  rm -f "$CACHING_PATCH"
  exit 1
fi

echo "Applying caching.patch..."
if ! git apply --check "$CACHING_PATCH" 2>/dev/null; then
  echo ""
  echo "❌ CACHING PATCH FAILED TO APPLY"
  echo ""
  echo "Attempting to apply for diagnostics..."
  git apply "$CACHING_PATCH" 2>&1 || true
  echo ""
  echo "Failed files:"
  find . -name "*.rej" -type f 2>/dev/null || echo "  None found"
  echo ""
  echo "The caching patch (from opencode-cached) may need updating for this upstream version."
  echo "See: https://github.com/johnnymo87/opencode-cached"
  rm -f "$CACHING_PATCH"
  exit 1
fi

git apply "$CACHING_PATCH"
echo "✓ Caching patch applied"
rm -f "$CACHING_PATCH"

# --- Patch 2: Vim keybindings (local) ---

echo "Applying vim.patch..."
if ! git apply --check "$VIM_PATCH" 2>/dev/null; then
  echo ""
  echo "❌ VIM PATCH FAILED TO APPLY"
  echo ""
  echo "Attempting to apply for diagnostics..."
  git apply "$VIM_PATCH" 2>&1 || true
  echo ""
  echo "Failed files:"
  find . -name "*.rej" -type f 2>/dev/null || echo "  None found"
  echo ""
  echo "The vim patch may need updating for this upstream version."
  echo "Source PR: https://github.com/anomalyco/opencode/pull/12679"
  exit 1
fi

git apply "$VIM_PATCH"
echo "✓ Vim patch applied"

# --- Summary ---

echo ""
echo "✓ Both patches applied successfully"
echo ""
echo "Files modified:"
git status --short

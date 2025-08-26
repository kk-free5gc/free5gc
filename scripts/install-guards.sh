#!/usr/bin/env bash
set -euo pipefail

HOOK_SRC="scripts/hooks/pre-push"

if [ ! -x "$HOOK_SRC" ]; then
  echo "Hook not found or not executable: $HOOK_SRC" >&2
  exit 1
fi

echo "Installing upstream push guards (top-level + submodules)..."

# Top-level
mkdir -p .git/hooks
cp -f "$HOOK_SRC" .git/hooks/pre-push
chmod +x .git/hooks/pre-push
# If upstream exists, disable pushes
git remote | grep -qx upstream && git remote set-url --push upstream DISABLED || true

# Submodules listed in .gitmodules
SUBS="$(git config --file .gitmodules --get-regexp '^submodule\..*\.path$' | awk '{print $2}')"
for d in $SUBS; do
  echo " -> $d"
  hooks_dir="$(git -C "$d" rev-parse --git-path hooks)"
  mkdir -p "$hooks_dir"
  cp -f "$HOOK_SRC" "$hooks_dir/pre-push"
  chmod +x "$hooks_dir/pre-push"
  # If upstream exists in submodule, disable pushes
  git -C "$d" remote | grep -qx upstream && git -C "$d" remote set-url --push upstream DISABLED || true
done

echo "✅ Guards installed."
echo "   (If you later add an 'upstream' remote, pushes to free5gc/* will still be blocked by the hook.)"

#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$PWD"
while [ "$REPO_ROOT" != "/" ] && [ ! -f "$REPO_ROOT/pnpm-lock.yaml" ]; do
  REPO_ROOT="$(dirname "$REPO_ROOT")"
done

# Ensure @n8n/vitest-config is compiled
if [ -d "$REPO_ROOT/packages/@n8n/vitest-config" ] && [ ! -f "$REPO_ROOT/packages/@n8n/vitest-config/dist/node-decorators.js" ]; then
  echo "📦 [migrate-runner] Pre-compiling @n8n/vitest-config..."
  mkdir -p "$REPO_ROOT/packages/@n8n/vitest-config/node_modules/@n8n"
  if [ ! -e "$REPO_ROOT/packages/@n8n/vitest-config/node_modules/@n8n/typescript-config" ] && [ -d "$REPO_ROOT/packages/@n8n/typescript-config" ]; then
    ln -s "../../typescript-config" "$REPO_ROOT/packages/@n8n/vitest-config/node_modules/@n8n/typescript-config" 2>/dev/null || true
  fi
  (cd "$REPO_ROOT/packages/@n8n/vitest-config" && pnpm build:unchecked 2>/dev/null || pnpm build) || true
fi

exec pnpm test:postgres:migrations "$@"

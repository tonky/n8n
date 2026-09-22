#!/usr/bin/env bash
set -euo pipefail

# typecheck-runner.sh: Component-scoped TypeScript verification
CURRENT_PKG=$(node -p "try { require('./package.json').name } catch(e) { '' }" 2>/dev/null || true)

if [ -f "scripts/generate-migration-index.mjs" ]; then
  node scripts/generate-migration-index.mjs || true
fi

if [ -n "$CURRENT_PKG" ] && [ -f "../../turbo.json" ]; then
  echo "🔍 [typecheck-runner] Running scoped typecheck via turbo for '$CURRENT_PKG'..."
  pnpm turbo run typecheck --filter="${CURRENT_PKG}" --concurrency=2
elif [ -n "$CURRENT_PKG" ] && [ -f "../../../turbo.json" ]; then
  echo "🔍 [typecheck-runner] Running scoped typecheck via turbo for '$CURRENT_PKG'..."
  pnpm turbo run typecheck --filter="${CURRENT_PKG}" --concurrency=2
elif [ -f "tsconfig.json" ]; then
  echo "🔍 [typecheck-runner] Running tsc --noEmit..."
  pnpm exec tsc -p tsconfig.json --noEmit
else
  echo "🔍 [typecheck-runner] Running generic tsc --noEmit..."
  tsc --noEmit
fi

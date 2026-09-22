#!/usr/bin/env bash
set -euo pipefail

# typecheck-runner.sh: Component-scoped TypeScript verification
CURRENT_PKG=$(node -p "try { require('./package.json').name } catch(e) { '' }" 2>/dev/null || true)

if [ -f "scripts/generate-migration-index.mjs" ]; then
  node scripts/generate-migration-index.mjs 2>/dev/null || true
fi

# Pre-warm upstream declarations into dist/ using turbo cache and fast unchecked builds
if [ -n "$CURRENT_PKG" ]; then
  pnpm turbo run build:unchecked --filter="${CURRENT_PKG}^..." --filter="!n8n-editor-ui" 2>/dev/null || true
fi

echo "🔍 [typecheck-runner] Running scoped TypeScript typecheck for '$CURRENT_PKG'..."
export NODE_OPTIONS="${NODE_OPTIONS:---max-old-space-size=6144}"

if [ -x "./node_modules/.bin/tsc" ]; then
  exec ./node_modules/.bin/tsc -p tsconfig.json --noEmit
elif [ -x "../../node_modules/.bin/tsc" ]; then
  exec ../../node_modules/.bin/tsc -p tsconfig.json --noEmit
elif [ -x "../../../node_modules/.bin/tsc" ]; then
  exec ../../../node_modules/.bin/tsc -p tsconfig.json --noEmit
elif command -v pnpm >/dev/null 2>&1; then
  exec pnpm exec tsc -p tsconfig.json --noEmit
else
  exec npx tsc -p tsconfig.json --noEmit
fi

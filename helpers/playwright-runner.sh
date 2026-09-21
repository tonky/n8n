#!/usr/bin/env bash
set -eo pipefail

export TZ=UTC
export PGTZ=UTC
export NODE_COMPILE_CACHE="${NODE_COMPILE_CACHE:-/tmp/.node_compile_cache}"
export NODE_OPTIONS="${NODE_OPTIONS:-} --max-old-space-size=512"
export PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-/tmp/.cache/ms-playwright}"
export PNPM_MANAGE_PACKAGE_MANAGER_VERSIONS=false

# Find repo root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VITEST_BIN="$REPO_ROOT/packages/cli/node_modules/.bin/vitest"

TARGETS=("$@")

if [ ${#TARGETS[@]} -eq 0 ]; then
  echo "🎯 [enact:playwright] Running Playwright package test suite..."
  exec "$VITEST_BIN" run --config "$REPO_ROOT/packages/testing/playwright/vitest.config.ts"
fi

SPECS=()
UNITS=()

for target in "${TARGETS[@]}"; do
  if [[ "$target" == *".spec.ts" ]]; then
    SPECS+=("$target")
  else
    UNITS+=("$target")
  fi
done

if [ ${#UNITS[@]} -gt 0 ]; then
  echo "🎯 [enact:playwright] Executing ${#UNITS[@]} unit/framework test target(s)..."
  "$VITEST_BIN" run "${UNITS[@]}"
fi

if [ ${#SPECS[@]} -gt 0 ]; then
  echo "🎯 [enact:playwright] Executing ${#SPECS[@]} Playwright E2E spec(s) with isolated environment..."
  node "$REPO_ROOT/packages/testing/playwright/scripts/run-local-isolated.mjs" "${SPECS[@]}"
fi

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

# Ensure workspace build artifacts exist for internal packages
if [ -d "$REPO_ROOT/packages/@n8n" ]; then
  TSC_BIN="$REPO_ROOT/node_modules/.bin/tsc"
  if [ -d "$REPO_ROOT/packages/@n8n/vitest-config" ] && [ ! -f "$REPO_ROOT/packages/@n8n/vitest-config/dist/frontend.js" ]; then
    echo "📦 [playwright-runner] Compiling @n8n/vitest-config..."
    if [ -x "$TSC_BIN" ]; then
      (cd "$REPO_ROOT/packages/@n8n/vitest-config" && "$TSC_BIN" -p tsconfig.build.json --noCheck) || true
    else
      (cd "$REPO_ROOT/packages/@n8n/vitest-config" && pnpm build) || true
    fi
  fi

  echo "📦 [playwright-runner] Compiling workspace dependencies via turbo..."
  (cd "$REPO_ROOT" && pnpm turbo run build:unchecked --filter=n8n-playwright^...) || true
fi

TARGETS=("$@")

if [ ${#TARGETS[@]} -eq 0 ] && [ -n "${ENACT_TARGETS_FILE:-}" ] && [ -f "$ENACT_TARGETS_FILE" ]; then
  mapfile -t TARGETS < <(rg '\S' "$ENACT_TARGETS_FILE" || true)
fi

if [ -n "${PLAYWRIGHT_BROWSERS_PATH:-}" ]; then
  mkdir -p "$PLAYWRIGHT_BROWSERS_PATH"
  if [ -z "$(fd -t x chrome "$PLAYWRIGHT_BROWSERS_PATH" 2>/dev/null || true)" ]; then
    echo "🌐 [playwright-runner] Playwright browser not found in $PLAYWRIGHT_BROWSERS_PATH, installing chromium..."
    pnpm --filter=n8n-playwright exec playwright install chromium || true
  fi
fi

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

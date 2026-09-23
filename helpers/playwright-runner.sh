#!/usr/bin/env bash
set -eo pipefail

export TZ=UTC
export PGTZ=UTC
export NODE_COMPILE_CACHE="${NODE_COMPILE_CACHE:-/tmp/.node_compile_cache}"
export NODE_OPTIONS="${NODE_OPTIONS:-} --max-old-space-size=4096"
export PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-/tmp/.cache/ms-playwright}"
export PNPM_MANAGE_PACKAGE_MANAGER_VERSIONS=false
export N8N_ENCRYPTION_KEY="${N8N_ENCRYPTION_KEY:-e2e-test-encryption-key-n8n}"
# Isolated Playwright runner uses local throwaway SQLite instance per spec
export DB_TYPE=sqlite
unset DB_POSTGRESDB_HOST DB_POSTGRESDB_PORT DB_POSTGRESDB_DATABASE DB_POSTGRESDB_USER DB_POSTGRESDB_PASSWORD

# Find repo root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VITEST_BIN="$REPO_ROOT/packages/cli/node_modules/.bin/vitest"

# Invalidate stale SQLite template if created with different encryption key
if [ -d "/tmp/n8n-e2e-template/.n8n" ]; then
  CACHED_KEY=$(node -e 'try { const cfg = JSON.parse(require("fs").readFileSync("/tmp/n8n-e2e-template/.n8n/config")); console.log(cfg.encryptionKey || "") } catch (_) {}' 2>/dev/null || true)
  if [ "$CACHED_KEY" != "$N8N_ENCRYPTION_KEY" ]; then
    echo "⚠️  [playwright-runner] Stale SQLite template detected (key '$CACHED_KEY' != '$N8N_ENCRYPTION_KEY'). Wiping template cache."
    rm -rf /tmp/n8n-e2e-template
  fi
fi

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

  if [ ! -f "$REPO_ROOT/packages/cli/dist/constants.js" ] || [ ! -d "$REPO_ROOT/packages/frontend/editor-ui/dist" ]; then
    echo "📦 [playwright-runner] Compiling workspace dependencies via turbo..."
    (cd "$REPO_ROOT" && pnpm turbo run build:unchecked --filter=n8n-playwright^... --filter=n8n... --filter=n8n-editor-ui...)
  else
    echo "⚡ [playwright-runner] Build artifacts already present in dist/, skipping turbo build"
  fi
fi

TARGETS=("$@")

if [ ${#TARGETS[@]} -eq 0 ] && [ -n "${ENACT_TARGETS_FILE:-}" ] && [ -f "$ENACT_TARGETS_FILE" ]; then
  mapfile -t TARGETS < <(rg '\S' "$ENACT_TARGETS_FILE" || true)
fi

if [ -n "${PLAYWRIGHT_BROWSERS_PATH:-}" ]; then
  mkdir -p "$PLAYWRIGHT_BROWSERS_PATH"
  HAS_BROWSER=""
  if compgen -G "$PLAYWRIGHT_BROWSERS_PATH/chromium-*" >/dev/null 2>&1; then
    HAS_BROWSER="true"
  elif [ -d "$HOME/.cache/ms-playwright" ] && compgen -G "$HOME/.cache/ms-playwright/chromium-*" >/dev/null 2>&1; then
    echo "📦 [playwright-runner] Copying restored browsers from $HOME/.cache/ms-playwright to $PLAYWRIGHT_BROWSERS_PATH..."
    cp -r "$HOME/.cache/ms-playwright/." "$PLAYWRIGHT_BROWSERS_PATH/" 2>/dev/null || true
    HAS_BROWSER="true"
  fi

  if [ -z "$HAS_BROWSER" ]; then
    echo "🌐 [playwright-runner] Playwright browser not found in $PLAYWRIGHT_BROWSERS_PATH, installing chromium..."
    pnpm --filter=n8n-playwright exec playwright install chromium || true
  else
    echo "✅ [playwright-runner] Playwright browser already warm in $PLAYWRIGHT_BROWSERS_PATH"
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

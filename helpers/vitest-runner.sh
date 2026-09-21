#!/usr/bin/env bash
set -euo pipefail

# vitest-runner.sh: Dispatches targeted tests to unit (SQLite) or integration (Postgres) runner
TARGETS=("$@")

export TZ=UTC
export PGTZ=UTC
export PNPM_MANAGE_PACKAGE_MANAGER_VERSIONS=false
export NODE_COMPILE_CACHE="${NODE_COMPILE_CACHE:-/tmp/.node_compile_cache}"
export NODE_OPTIONS="${NODE_OPTIONS:-} --max-old-space-size=512"
MAX_WORKERS="${MAX_WORKERS:-2}"

VITEST_BIN="./node_modules/.bin/vitest"
if [ ! -f "$VITEST_BIN" ]; then
  VITEST_BIN="../../node_modules/.bin/vitest"
fi
if [ ! -f "$VITEST_BIN" ]; then
  VITEST_BIN="../../../node_modules/.bin/vitest"
fi
if [ ! -f "$VITEST_BIN" ]; then
  REPO_ROOT="$PWD"
  while [ "$REPO_ROOT" != "/" ] && [ ! -f "$REPO_ROOT/pnpm-lock.yaml" ]; do
    REPO_ROOT="$(dirname "$REPO_ROOT")"
  done
  if [ -f "$REPO_ROOT/pnpm-lock.yaml" ]; then
    echo "📦 [vitest-runner] Vitest binary missing; restoring dependencies in $REPO_ROOT..."
    (cd "$REPO_ROOT" && pnpm install --prefer-offline 2>/dev/null || pnpm install --no-frozen-lockfile)
  fi
  if [ -f "./node_modules/.bin/vitest" ]; then
    VITEST_BIN="./node_modules/.bin/vitest"
  elif [ -f "../../node_modules/.bin/vitest" ]; then
    VITEST_BIN="../../node_modules/.bin/vitest"
  elif [ -f "../../../node_modules/.bin/vitest" ]; then
    VITEST_BIN="../../../node_modules/.bin/vitest"
  fi
fi

# Ensure @n8n/vitest-config is compiled if present
REPO_ROOT_CHECK="$PWD"
while [ "$REPO_ROOT_CHECK" != "/" ] && [ ! -f "$REPO_ROOT_CHECK/pnpm-lock.yaml" ]; do
  REPO_ROOT_CHECK="$(dirname "$REPO_ROOT_CHECK")"
done
if [ -d "$REPO_ROOT_CHECK/packages/@n8n/vitest-config" ] && [ ! -f "$REPO_ROOT_CHECK/packages/@n8n/vitest-config/dist/node-decorators.js" ]; then
  echo "📦 [vitest-runner] Compiling @n8n/vitest-config..."
  TSC_BIN="$REPO_ROOT_CHECK/node_modules/.bin/tsc"
  if [ -x "$TSC_BIN" ]; then
    (cd "$REPO_ROOT_CHECK/packages/@n8n/vitest-config" && "$TSC_BIN" -p tsconfig.build.json) || true
  else
    (cd "$REPO_ROOT_CHECK/packages/@n8n/vitest-config" && pnpm build) || true
  fi
fi

if [ ${#TARGETS[@]} -eq 0 ]; then
  echo "🎯 [enact] No targets specified, running unit test suite"
  export N8N_LOG_LEVEL=silent
  export DB_SQLITE_POOL_SIZE=4
  export DB_TYPE=sqlite
  exec "$VITEST_BIN" run
fi

UNITS=()
INTEGRATIONS=()

for target in "${TARGETS[@]}"; do
  if [[ "$target" == *".integration.test.ts" ]] || [[ "$target" == *"/test/integration/"* ]]; then
    INTEGRATIONS+=("$target")
  else
    UNITS+=("$target")
  fi
done

if [ ${#UNITS[@]} -gt 0 ]; then
  echo "🎯 [enact] Executing ${#UNITS[@]} unit test target(s)..."
  N8N_LOG_LEVEL=silent DB_SQLITE_POOL_SIZE=4 DB_TYPE=sqlite "$VITEST_BIN" run --maxWorkers "$MAX_WORKERS" "${UNITS[@]}"
fi

if [ ${#INTEGRATIONS[@]} -gt 0 ]; then
  echo "🎯 [enact] Executing ${#INTEGRATIONS[@]} integration test target(s) against PostgreSQL..."
  N8N_LOG_LEVEL=silent DB_TYPE=postgresdb DB_POSTGRESDB_USER=postgres PGUSER=postgres DB_POSTGRESDB_DATABASE=n8n DB_POSTGRESDB_SCHEMA=alt_schema DB_TABLE_PREFIX=test_ "$VITEST_BIN" run --maxWorkers "$MAX_WORKERS" --config vitest.config.integration.ts "${INTEGRATIONS[@]}"
fi

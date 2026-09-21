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

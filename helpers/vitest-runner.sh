#!/usr/bin/env bash
set -euo pipefail

# vitest-runner.sh: Dispatches targeted tests to unit (SQLite) or integration (Postgres) runner
TARGETS=("$@")

export TZ=UTC
export PGTZ=UTC
export PNPM_MANAGE_PACKAGE_MANAGER_VERSIONS=false
export NODE_COMPILE_CACHE="${NODE_COMPILE_CACHE:-/tmp/.node_compile_cache}"
export NODE_OPTIONS="${NODE_OPTIONS:-} --max-old-space-size=4096"
MAX_WORKERS="${MAX_WORKERS:-2}"

REPO_ROOT="$PWD"
while [ "$REPO_ROOT" != "/" ] && [ ! -f "$REPO_ROOT/pnpm-lock.yaml" ]; do
  REPO_ROOT="$(dirname "$REPO_ROOT")"
done

# Ensure local node_modules exists for the component
if [ ! -d "node_modules" ] && [ -f "$REPO_ROOT/pnpm-lock.yaml" ]; then
  echo "📦 [vitest-runner] Local node_modules missing, running pnpm install..."
  (cd "$REPO_ROOT" && pnpm install --prefer-offline 2>/dev/null || pnpm install --no-frozen-lockfile) || true
fi

# Ensure workspace build artifacts exist for internal packages
if [ -d "$REPO_ROOT/packages/@n8n" ]; then
  TSC_BIN="$REPO_ROOT/node_modules/.bin/tsc"
  if [ -d "$REPO_ROOT/packages/@n8n/vitest-config" ] && [ ! -f "$REPO_ROOT/packages/@n8n/vitest-config/dist/frontend.js" ]; then
    echo "📦 [vitest-runner] Compiling @n8n/vitest-config..."
    if [ -x "$TSC_BIN" ]; then
      (cd "$REPO_ROOT/packages/@n8n/vitest-config" && "$TSC_BIN" -p tsconfig.build.json --noCheck) || true
    else
      (cd "$REPO_ROOT/packages/@n8n/vitest-config" && pnpm build) || true
    fi
  fi

  if [ -d "$REPO_ROOT/packages/@n8n/di" ] && [ ! -f "$REPO_ROOT/packages/@n8n/di/dist/di.js" ]; then
    echo "📦 [vitest-runner] Fast-compiling @n8n/di..."
    if [ -x "$TSC_BIN" ]; then
      (cd "$REPO_ROOT/packages/@n8n/di" && "$TSC_BIN" -p tsconfig.build.json --noCheck) || true
    fi
  fi

  if [ -d "$REPO_ROOT/packages/@n8n/typeorm" ] && [ ! -f "$REPO_ROOT/packages/@n8n/typeorm/dist/index.js" ]; then
    echo "📦 [vitest-runner] Fast-compiling @n8n/typeorm..."
    if [ -x "$TSC_BIN" ]; then
      (cd "$REPO_ROOT/packages/@n8n/typeorm" && "$TSC_BIN" -p tsconfig.build.json --noCheck) || true
    fi
  fi
fi

run_vitest() {
  if [ -x "./node_modules/.bin/vitest" ]; then
    ./node_modules/.bin/vitest "$@"
  elif [ -x "$REPO_ROOT/node_modules/.bin/vitest" ]; then
    "$REPO_ROOT/node_modules/.bin/vitest" "$@"
  elif [ -x "../../node_modules/.bin/vitest" ]; then
    ../../node_modules/.bin/vitest "$@"
  elif [ -x "../../../node_modules/.bin/vitest" ]; then
    ../../../node_modules/.bin/vitest "$@"
  elif command -v pnpm >/dev/null 2>&1; then
    pnpm exec vitest "$@"
  else
    npx vitest "$@"
  fi
}

SHARD_OPTS=()
if [ -n "${ENACT_SHARD_INDEX:-}" ] && [ -n "${ENACT_SHARD_TOTAL:-}" ]; then
  SHARD_OPTS=(--shard="${ENACT_SHARD_INDEX}/${ENACT_SHARD_TOTAL}")
elif [ -n "${SHARD:-}" ] && [ -n "${TOTAL_SHARDS:-}" ]; then
  SHARD_OPTS=(--shard="${SHARD}/${TOTAL_SHARDS}")
fi

if [ ${#TARGETS[@]} -eq 0 ]; then
  echo "🎯 [enact] No targets specified, running unit test suite ${SHARD_OPTS[*]:-}"
  export N8N_LOG_LEVEL=silent
  export DB_SQLITE_POOL_SIZE=4
  export DB_TYPE=sqlite
  run_vitest run "${SHARD_OPTS[@]}"
  exit $?
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
  N8N_LOG_LEVEL=silent DB_SQLITE_POOL_SIZE=4 DB_TYPE=sqlite run_vitest run --maxWorkers "$MAX_WORKERS" "${UNITS[@]}"
fi

if [ ${#INTEGRATIONS[@]} -gt 0 ]; then
  echo "🎯 [enact] Executing ${#INTEGRATIONS[@]} integration test target(s) against PostgreSQL..."
  N8N_LOG_LEVEL=silent DB_TYPE=postgresdb DB_POSTGRESDB_USER=postgres PGUSER=postgres DB_POSTGRESDB_DATABASE=n8n DB_POSTGRESDB_SCHEMA=alt_schema DB_TABLE_PREFIX=test_ run_vitest run --maxWorkers "$MAX_WORKERS" --config vitest.config.integration.ts "${INTEGRATIONS[@]}"
fi


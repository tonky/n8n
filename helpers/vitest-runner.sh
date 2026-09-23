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
export NODE_PATH="${REPO_ROOT}/node_modules:${REPO_ROOT}/packages/cli/node_modules:${REPO_ROOT}/packages/frontend/editor-ui/node_modules:${NODE_PATH:-}"

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

  CURRENT_PKG=$(node -p "try { require('./package.json').name } catch(e) { '' }" 2>/dev/null || true)
  FILTER_ARGS=()
  if [ -n "$CURRENT_PKG" ]; then
    FILTER_ARGS+=(--filter="${CURRENT_PKG}^...")
  elif [ -d "$REPO_ROOT/packages/@n8n/db" ]; then
    FILTER_ARGS+=(--filter=@n8n/db^...)
  elif [ -d "$REPO_ROOT/packages/cli" ]; then
    FILTER_ARGS+=(--filter=n8n^...)
  fi
  if [ -f "$REPO_ROOT/packages/frontend/editor-ui/package.json" ]; then
    FILTER_ARGS+=(--filter="!n8n-editor-ui")
  fi

  TURBO_SUCCESS=false
  if [ -f "$REPO_ROOT/turbo.json" ]; then
    if (cd "$REPO_ROOT" && pnpm turbo run build:unchecked "${FILTER_ARGS[@]}"); then
      TURBO_SUCCESS=true
    fi
  fi

  # Self-healing fallback for critical TypeScript packages if turbo was unconfigured or failed
  if [ "$TURBO_SUCCESS" != "true" ]; then
    echo "📦 [vitest-runner] Turbo build skipped or failed; compiling checked-out workspace packages directly..."
    # Explicit fallback for @n8n/db
    if [ -d "$REPO_ROOT/packages/@n8n/db" ]; then
      if [ -f "$REPO_ROOT/packages/@n8n/db/scripts/generate-migration-index.mjs" ]; then
        node "$REPO_ROOT/packages/@n8n/db/scripts/generate-migration-index.mjs" 2>/dev/null || true
      fi
      if [ -x "$TSC_BIN" ]; then
        (cd "$REPO_ROOT/packages/@n8n/db" && "$TSC_BIN" -p tsconfig.build.json --noCheck) || true
      else
        (cd "$REPO_ROOT/packages/@n8n/db" && pnpm build:unchecked) || true
      fi
    fi

    for fallback_pkg in di typeorm tournament codemirror-lang-html; do
      pkg_dir="$REPO_ROOT/packages/@n8n/$fallback_pkg"
      if [ -d "$pkg_dir" ]; then
        if [ -x "$TSC_BIN" ] && [ -f "$pkg_dir/tsconfig.build.json" ]; then
          (cd "$pkg_dir" && "$TSC_BIN" -p tsconfig.build.json --noCheck) || true
        else
          (cd "$pkg_dir" && pnpm build) || true
        fi
      fi
    done
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


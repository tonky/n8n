#!/usr/bin/env bash
set -euo pipefail

# vitest-runner.sh: Dispatches targeted tests to unit (SQLite) or integration (Postgres) runner
drop_template() {
  [ -n "${N8N_TEST_TEMPLATE_DB:-}" ] || return 0
  local psql=(psql -h "${DB_POSTGRESDB_HOST:-127.0.0.1}" -p "${DB_POSTGRESDB_PORT:?the postgres port (enve.cue)}" -U postgres -d n8n -q)
  "${psql[@]}" -c "UPDATE pg_database SET datistemplate = false WHERE datname = '$N8N_TEST_TEMPLATE_DB'" \
    -c "DROP DATABASE IF EXISTS $N8N_TEST_TEMPLATE_DB" >/dev/null 2>&1 || true
}
if [ "${1:-}" = --release-fixture ]; then
  drop_template
  exit 0
fi
SETUP_FIXTURE=0
if [ "${1:-}" = --setup-fixture ]; then
  SETUP_FIXTURE=1
  shift
  if [ -n "${ENACT_FOOTPRINT_DIR:-}" ] || [ "${N8N_TEST_DISABLE_TEMPLATE_DB:-}" = 1 ] ||
    [ -n "${N8N_TEST_TEMPLATE_DB:-}" ] || [ ! -f vitest.config.integration.ts ]; then
    exit 0
  fi
  if [ $# -gt 0 ]; then
    has_integration=0
    for target in "$@"; do
      clean_target="${target%%::*}"
      if [[ "$clean_target" == *".integration.test.ts" ]] || [[ "/$clean_target" == *"/test/integration/"* ]]; then
        has_integration=1
        break
      fi
    done
    [ "$has_integration" = 1 ] || exit 0
  fi
fi
TARGETS=("$@")

export TZ=UTC
export PGTZ=UTC
export PNPM_MANAGE_PACKAGE_MANAGER_VERSIONS=false
export VITE_CONFIG_NATIVE_IGNORE_WARNING=true
export TURBO_TELEMETRY_DISABLED=1
export NODE_COMPILE_CACHE="${NODE_COMPILE_CACHE:-/tmp/.node_compile_cache}"
if [ -n "${ENACT_ATTRIBUTION_FILE:-}" ] || [ -n "${ENACT_FOOTPRINT_DIR:-}" ]; then
  [[ "${NODE_OPTIONS:-}" == *"--max-old-space-size="* ]] || export NODE_OPTIONS="${NODE_OPTIONS:-} --max-old-space-size=3072"
  NPROCS=$(nproc 2>/dev/null || echo 2)
  [ "$NPROCS" -le 2 ] || NPROCS=2
  MAX_WORKERS="${MAX_WORKERS:-$NPROCS}"
elif [ "${VITEST_MIGRATION:-}" = both ]; then
  [[ "${NODE_OPTIONS:-}" == *"--max-old-space-size="* ]] || export NODE_OPTIONS="${NODE_OPTIONS:-} --max-old-space-size=2560"
  NPROCS=$(nproc 2>/dev/null || echo 2)
  MAX_WORKERS="${MAX_WORKERS:-${ENACT_SHARD_WORKERS:-$NPROCS}}"
else
  [[ "${NODE_OPTIONS:-}" == *"--max-old-space-size="* ]] || export NODE_OPTIONS="${NODE_OPTIONS:-} --max-old-space-size=4096"
  NPROCS=$(nproc 2>/dev/null || echo 2)
  MAX_WORKERS="${MAX_WORKERS:-${ENACT_SHARD_WORKERS:-$NPROCS}}"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$PWD"
while [ "$REPO_ROOT" != "/" ] && [ ! -f "$REPO_ROOT/pnpm-workspace.yaml" ] && [ ! -f "$REPO_ROOT/pnpm-lock.yaml" ]; do
  REPO_ROOT="$(dirname "$REPO_ROOT")"
done
LOCAL_NM="$PWD/node_modules"
if [ "$PWD" = "$REPO_ROOT/packages/@n8n/vitest-config" ]; then
  export NODE_PATH="$LOCAL_NM"
elif [ -d "$LOCAL_NM" ]; then
  export NODE_PATH="${LOCAL_NM}:${REPO_ROOT}/node_modules:${NODE_PATH:-}"
else
  export NODE_PATH="${REPO_ROOT}/node_modules:${NODE_PATH:-}"
fi

# The installed tree comes from the prepare phase (`toolchain.node`'s frozen install, before
# a run's shards; CI's install step), never from here: shards installing side by side into one
# node_modules collide. Without it, fail loudly instead of running unpinned.
if [ -f "$REPO_ROOT/pnpm-lock.yaml" ] && [ ! -d "$REPO_ROOT/node_modules" ]; then
  echo "❌ [vitest-runner] $REPO_ROOT/node_modules is missing: run through \`enact run\` (its prepare phase installs) or \`pnpm install --frozen-lockfile\`" >&2
  exit 1
fi

# The repairs the installed tree needs (links, resolution, native-addon fallbacks).
if [ -d "$REPO_ROOT/node_modules" ] && [ "${N8N_NODE_MODULES_REPAIRED:-}" != 1 ]; then
  if [ "$SETUP_FIXTURE" = 1 ]; then
    REPO_ROOT="$REPO_ROOT" "$SCRIPT_DIR/repair-node-modules.sh" >&2
  else
    REPO_ROOT="$REPO_ROOT" "$SCRIPT_DIR/repair-node-modules.sh"
  fi
  export N8N_NODE_MODULES_REPAIRED=1
fi

# Node 24's IncomingMessage symbols (repair-node-modules.sh writes the preload).
HTTP_PRELOAD="$REPO_ROOT/node_modules/.enact-node24-http-preload.cjs"
if [ -f "$HTTP_PRELOAD" ] && [[ "${NODE_OPTIONS:-}" != *".enact-node24-http-preload.cjs"* ]]; then
  export NODE_OPTIONS="${NODE_OPTIONS:-} --require $HTTP_PRELOAD"
fi

# Point @n8n/instance-ai's browser-runtime at enve's Playwright Chromium, and on Linux
# expose its store RUNPATH (libdbus-1.so.3, libxcb.so.1) for node-screenshots' native addon.
if [ -n "${PLAYWRIGHT_BROWSERS_PATH:-}" ] && [ -d "$PLAYWRIGHT_BROWSERS_PATH" ]; then
  for browser in \
    "$PLAYWRIGHT_BROWSERS_PATH"/chromium*/chrome*/chrome-headless-shell \
    "$PLAYWRIGHT_BROWSERS_PATH"/chromium*/chrome*/headless_shell \
    "$PLAYWRIGHT_BROWSERS_PATH"/chromium*/chrome*/chrome \
    "$PLAYWRIGHT_BROWSERS_PATH"/chromium*/chrome*/*.app/Contents/MacOS/*; do
    if [ -x "$browser" ]; then
      export N8N_EVAL_BROWSER_EXECUTABLE="${N8N_EVAL_BROWSER_EXECUTABLE:-$browser}"
      if [ "$(uname -s)" = Linux ]; then
        if ! "$browser" --version >/dev/null 2>&1; then
          enve cache pull "$REPO_ROOT/enve.lock" \
            --cache "${ENACT_R2_BUCKET:-https://pub-30fd937eb7634039b8c49d49bfec91a9.r2.dev}" \
            -j 16 >&2 || true
        fi
        PW_RPATH_CACHE="$REPO_ROOT/node_modules/.enact-playwright-rpath-v1"
        if [ ! -f "$PW_RPATH_CACHE" ] && [ -d "$REPO_ROOT/node_modules" ]; then
          rg -ao "/[^:[:space:]]+/lib(:/[^:[:space:]]+/lib)+" "$browser" 2>/dev/null | head -n 1 > "$PW_RPATH_CACHE" || true
        fi
        if [ -s "$PW_RPATH_CACHE" ]; then
          pw_rpath="$(<"$PW_RPATH_CACHE")"
          [[ ":${LD_LIBRARY_PATH:-}:" == *":$pw_rpath:"* ]] || export LD_LIBRARY_PATH="${pw_rpath}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        fi
      fi
      break
    fi
  done
fi

if [ -d "$REPO_ROOT/packages/@n8n" ]; then
  # The workspace packages this one imports from their builds (`<pkg>^...`), with its own
  # when it was handed another package's tests (`../core/...`: they read its build). Every
  # run: turbo builds what changed since its last build (build-workspace-deps.sh); the runs
  # this one starts (a handed package's, footprints.sh's traced run) find them built.
  CURRENT_PKG=$(node -p "require('./package.json').name || ''" 2>/dev/null || true)
  if [ -n "$CURRENT_PKG" ]; then
    filter="${CURRENT_PKG}^..."
    # A package whose tests load its own build (N8N_TESTS_READ_OWN_BUILD, components.cue).
    if [ "${N8N_TESTS_READ_OWN_BUILD:-}" = 1 ] || [ "$CURRENT_PKG" = "n8n" ]; then
      filter="${CURRENT_PKG}..."
    fi
    for target in "${TARGETS[@]}"; do
      case "$target" in ../*) filter="${CURRENT_PKG}..." ;; esac
    done
    if [ "$SETUP_FIXTURE" = 1 ]; then
      "$SCRIPT_DIR/build-workspace-deps.sh" "$filter" >&2 ||
        { echo "❌ [vitest-runner] building the workspace packages $CURRENT_PKG imports failed" >&2; exit 1; }
    else
      "$SCRIPT_DIR/build-workspace-deps.sh" "$filter" ||
        { echo "❌ [vitest-runner] building the workspace packages $CURRENT_PKG imports failed" >&2; exit 1; }
    fi
    export N8N_WORKSPACE_DEPS_BUILT=1
  fi
fi

if [ "$SETUP_FIXTURE" = 1 ]; then
  context=""
  if [ -e node_modules/@n8n/backend-test-utils ]; then
    export N8N_LOG_LEVEL=silent DB_TYPE=postgresdb DB_POSTGRESDB_USER=postgres PGUSER=postgres \
      DB_POSTGRESDB_DATABASE=n8n DB_POSTGRESDB_SCHEMA=alt_schema DB_TABLE_PREFIX=test_
    db="n8n_template_$$_$RANDOM"
    node "$SCRIPT_DIR/n8n-template-db.cjs" "$db" >&2 || exit
    context=$(printf '{"env":{"N8N_TEST_TEMPLATE_DB":"%s","N8N_WORKSPACE_DEPS_BUILT":"1"}}' "$db")
  elif [ "${N8N_WORKSPACE_DEPS_BUILT:-}" = 1 ]; then
    context='{"env":{"N8N_WORKSPACE_DEPS_BUILT":"1"}}'
  fi
  if [ -n "$context" ]; then
    if [ -n "${ENACT_FIXTURE_CONTEXT_FILE:-}" ]; then
      printf '%s\n' "$context" > "$ENACT_FIXTURE_CONTEXT_FILE"
    else
      printf '%s\n' "$context"
    fi
  fi
  exit 0
fi

# Targets of another package (`../core/src/...`): tests handed to this package's suite
# (`target_scope.handoff`). Each runs in its own package, under its own vitest config, as
# this script runs that package's: the giver's config sets up what they import.
package_of() {
  local dir
  dir="$(cd "$(dirname "$1")" && pwd)"
  while [ "$dir" != "$REPO_ROOT" ] && [ "$dir" != "/" ] && [ ! -f "$dir/package.json" ]; do
    dir="$(dirname "$dir")"
  done
  echo "$dir"
}
OWN=()
FOREIGN=()
for target in "${TARGETS[@]}"; do
  case "$target" in
    ../*) FOREIGN+=("$(cd "$(dirname "${target%%::*}")" && pwd)/$(basename "${target%%::*}")") ;;
    *) OWN+=("$target") ;;
  esac
done

# VITEST_RUNNER_ARGS: what a job adds to every vitest run and listing of its own targets
# (nodes-base's `integration`: `--config vitest.integration.config.ts --dir credentials`), so
# a suite under another config is listed, run and recorded as the unit suite is.
# Turbo's task logs and builds aren't tests. Exclude the directories and their descendants:
# Vitest's CLI patterns add to each config's excludes, for both listing and execution. A
# config's `**/*.test.ts` walk otherwise reads the package's own `dist` whenever a build is
# there, and that read is reached by every source built into it (nodes-base's integration
# tests: a credential's change selected all five).
DISCOVERY_ARGS=(--exclude '**/.turbo' --exclude '**/.turbo/**' --exclude '**/dist' --exclude '**/dist/**')
RUNNER_ARGS=()
[ -z "${VITEST_RUNNER_ARGS:-}" ] || read -ra RUNNER_ARGS <<<"$VITEST_RUNNER_ARGS"

INTEGRATION_CONFIG=""
if [ -f vitest.config.integration.ts ]; then
  INTEGRATION_CONFIG=vitest.config.integration.ts
elif [ -z "${VITEST_RUNNER_ARGS:-}" ] && [ -f vitest.integration.config.ts ] && [ "$PWD" != "$REPO_ROOT/packages/nodes-base" ]; then
  INTEGRATION_CONFIG=vitest.integration.config.ts
fi

UNITS=()
INTEGRATIONS=()
MIGRATIONS=()

for target in "${OWN[@]}"; do
  clean_target="${target%%::*}"
  # Targets are relative to the package (`test/integration/...`) or to the repository.
  # Only a package with an integration config runs them on PostgreSQL: core's run
  # under its one config, nodes-base's own config leaves them out (its integration job's).
  if [ -n "$INTEGRATION_CONFIG" ] && { [[ "$clean_target" == *".integration.test.ts" ]] || [[ "/$clean_target" == *"/test/integration/"* ]]; }; then
    INTEGRATIONS+=("$clean_target")
  elif [ -f vitest.config.migration.ts ] && { [ "${VITEST_MIGRATION:-}" = 1 ] || [ "${VITEST_MIGRATION:-}" = both ] || [[ "/$clean_target" == *"/test/migration/"* ]]; }; then
    MIGRATIONS+=("$clean_target")
  else
    UNITS+=("$clean_target")
  fi
done

# The targets vitest wouldn't run: its config's include/exclude leave them out
# (nodes-base's own config excludes its `*.integration.test.ts`, its integration job's),
# or they name no file. Given them beside others, vitest runs the others and passes: a test
# asked for and never run would read as passed. So the targets are listed first (`vitest list
# --filesOnly`: no test runs), each kind under the config that runs it, the handed ones in
# their package, and one vitest lists no file of fails the run. Once per run: the runs this
# one starts (a handed package's, the traced run of footprints.sh) don't list them again, so
# the listing's reads stay out of the footprints.
# unrun <vitest args...> -- <target...>: the targets vitest, run here with those args, runs
# no file of (a target is a filter: it runs the files whose path holds it). A config with
# projects lists a file once per project, as `[<project>] <file>`.
unrun() {
  local args=() listed target
  while [ "$1" != -- ]; do args+=("$1"); shift; done
  shift
  listed=$(pnpm exec vitest list --filesOnly ${args[@]+"${args[@]}"} ${RUNNER_ARGS[@]+"${RUNNER_ARGS[@]}"} "$@" "${DISCOVERY_ARGS[@]}" 2>/dev/null | awk -v d="$PWD/" '{ sub(/^\[[^]]*\] /, ""); print d $0 }') || true
  for target in "$@"; do
    [[ $listed == *"${target#./}"* ]] || echo "$target"
  done
}
if [ ${#TARGETS[@]} -gt 0 ] && [ -z "${VITEST_RUNNER_LISTED:-}" ]; then
  missing=()
  if [ ${#UNITS[@]} -gt 0 ]; then
    while IFS= read -r t; do missing+=("$t"); done < <(unrun -- "${UNITS[@]}")
  fi
  if [ ${#INTEGRATIONS[@]} -gt 0 ]; then
    while IFS= read -r t; do missing+=("$t"); done < <(unrun --config "$INTEGRATION_CONFIG" -- "${INTEGRATIONS[@]}")
  fi
  if [ ${#MIGRATIONS[@]} -gt 0 ]; then
    while IFS= read -r t; do missing+=("$t"); done < <(unrun --config vitest.config.migration.ts -- "${MIGRATIONS[@]}")
  fi
  for pkg in $(for f in ${FOREIGN[@]+"${FOREIGN[@]}"}; do package_of "$f"; done | sort -u); do
    in_pkg=()
    for f in "${FOREIGN[@]}"; do
      [ "$(package_of "$f")" = "$pkg" ] && in_pkg+=("${f#"$pkg"/}")
    done
    while IFS= read -r t; do missing+=("$pkg/$t"); done < <(cd "$pkg" && RUNNER_ARGS=() && unrun -- "${in_pkg[@]}")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    echo "❌ [vitest-runner] vitest runs no test file of ${#missing[@]} target(s) it was given (its config leaves them out, or they name no file): ${missing[*]}" >&2
    exit 1
  fi
  export VITEST_RUNNER_LISTED=1
fi

if [ "$PWD" = "$REPO_ROOT/packages/@n8n/instance-ai" ] && [ ! -f "$PWD/.data/.gitignore" ]; then
  mkdir -p "$PWD/.data"
  printf '*\n' > "$PWD/.data/.gitignore"
fi

# Footprints enact asks for (ENACT_FOOTPRINT_DIR: `enact run` recording while it runs,
# `enact reach record`): the wanted test files are traced one by one, the others run as
# here. After the set-up above, so the traced tests find it done and don't record it.
if [ -n "${ENACT_FOOTPRINT_DIR:-}" ]; then
  if [ "${VITEST_MIGRATION:-}" = both ]; then
    status=0
    VITEST_MIGRATION=1 "$SCRIPT_DIR/trace/footprints.sh" "$SCRIPT_DIR/vitest-runner.sh" ${TARGETS[@]+"${TARGETS[@]}"} || status=$?
    env -u PGHOST -u PGPORT -u PGDATABASE -u PGUSER -u PGPASSWORD \
      -u DB_POSTGRESDB_HOST -u DB_POSTGRESDB_PORT -u DB_POSTGRESDB_DATABASE \
      -u DB_POSTGRESDB_USER -u DB_POSTGRESDB_PASSWORD -u DB_POSTGRESDB_SCHEMA \
      -u DB_TABLE_PREFIX -u ENACT_FOOTPRINT_DIR -u ENACT_FOOTPRINT_TARGETS \
      VITEST_MIGRATION=1 DB_TYPE=sqlite DB_SQLITE_POOL_SIZE=4 \
      "$SCRIPT_DIR/vitest-runner.sh" ${TARGETS[@]+"${TARGETS[@]}"} || status=$?
    exit "$status"
  fi
  if [ "${DB_TYPE:-}" != sqlite ]; then
    exec "$SCRIPT_DIR/trace/footprints.sh" "$SCRIPT_DIR/vitest-runner.sh" ${TARGETS[@]+"${TARGETS[@]}"}
  fi
fi

# Transforms persist across runs under `.enact/state/cache/vitest/<pkg>-...` (keyed by
# package, DB mode and shard so the lockfile's two peer builds of vitest 5.0.1 never mix
# transforms across packages, parallel shards never race on rmdir, and node_modules stays
# clean; every run still reads the sources it uses, so traces see them): halves start-up.
# VITEST_FS_CACHE=0 turns it off.
CACHE_OPTS=()
if [ "${VITEST_FS_CACHE:-1}" != 0 ]; then
  PKG_CACHE_KEY=$(printf '%s' "${PWD#"$REPO_ROOT"/}" | tr '/@:' '___')
  CACHE_OPTS=(
    --fsModuleCache
    --fsModuleCachePath "$REPO_ROOT/.enact/state/cache/vitest/${PKG_CACHE_KEY}-${DB_TYPE:-default}-m${VITEST_MIGRATION:-0}-s${ENACT_SHARD_INDEX:-1}"
  )
fi

# The package's vitest, as its `pnpm test` runs it: pnpm sets the environment its scripts
# get (npm_config_user_agent: node-cli's commands pick the package manager they were run with).
# Traced by `enact trace run --attribution` (helpers/trace/trace-files.sh): one forked worker
# per test file, and the reporter saying which modules each loaded.
# A traced run is slower than a plain one (eBPF, one worker per file, shards side by side):
# its hooks get the most any config gives them (nodes-base's integration config, 120 s), not
# the 10 s default cli's unit config keeps for the module-loading `setupTestServer` of its
# `*.api.test.ts`, which a recording otherwise records as failed while plain runs pass.
ATTRIBUTION_ARGS=()
if [ -n "${ENACT_ATTRIBUTION_FILE:-}" ]; then
  VITEST_ATTR="${ENACT_RECORDERS_DIR:+$ENACT_RECORDERS_DIR/js/vitest-attribution.mjs}"
  if [ -z "$VITEST_ATTR" ] || [ ! -f "$VITEST_ATTR" ]; then
    if [ -f "$SCRIPT_DIR/trace/vitest-attribution.mjs" ]; then
      VITEST_ATTR="$SCRIPT_DIR/trace/vitest-attribution.mjs"
    else
      VITEST_ATTR="$REPO_ROOT/../../crates/enact-runner/recorders/js/vitest-attribution.mjs"
    fi
  fi
  # Scheduling results are read then rewritten; retain transform caching without
  # making the trace depend on its own results.json update.
  ATTRIBUTION_ARGS=(--no-cache --pool=forks --isolate --hookTimeout=120000 --testTimeout=120000 --reporter=default
    "--reporter=$VITEST_ATTR")
fi
run_vitest() {
  pnpm exec vitest "$@" ${RUNNER_ARGS[@]+"${RUNNER_ARGS[@]}"} ${ATTRIBUTION_ARGS[@]+"${ATTRIBUTION_ARGS[@]}"} "${DISCOVERY_ARGS[@]}"
}

# run_integration <vitest args...>: cli's integration config, against PostgreSQL.
# Its test files (testDb) clone a template database built once, as upstream's testcontainers
# setup has them, instead of each replaying every migration: workers migrating at once ran
# past the 30s hook timeout. The template is built in this run, so a traced run still reads
# the migrations. N8N_TEST_DISABLE_TEMPLATE_DB=1 (upstream's switch) migrates per file.
run_integration() (
  if [ -n "${ENACT_ATTRIBUTION_FILE:-}" ]; then
    mkdir -p "/tmp/enact-locks-$(id -u)"
    exec 9>"/tmp/enact-locks-$(id -u)/n8n-pg-${DB_POSTGRESDB_PORT:-5432}.flock"
    flock 9
  fi
  export N8N_LOG_LEVEL=silent DB_TYPE=postgresdb DB_POSTGRESDB_USER=postgres PGUSER=postgres \
    DB_POSTGRESDB_DATABASE=n8n DB_POSTGRESDB_SCHEMA=alt_schema DB_TABLE_PREFIX=test_
  TC_SHIM=""
  for candidate in \
    "$SCRIPT_DIR/trace/testcontainers-enve-shim.mjs" \
    "$REPO_ROOT/../../../crates/enact-runner/recorders/js/testcontainers-enve-shim.mjs" \
    "$REPO_ROOT/../../crates/enact-runner/recorders/js/testcontainers-enve-shim.mjs" \
    "${ENACT_RECORDERS_DIR:+$ENACT_RECORDERS_DIR/js/testcontainers-enve-shim.mjs}"; do
    if [ -n "$candidate" ] && [ -f "$candidate" ]; then
      TC_SHIM="$(realpath "$candidate")"
      break
    fi
  done
  if [ -n "$TC_SHIM" ] && [[ "${NODE_OPTIONS:-}" != *"testcontainers-enve-shim.mjs"* ]]; then
    export NODE_OPTIONS="${NODE_OPTIONS:-} --import $TC_SHIM"
  fi
  if [ "${N8N_TEST_DISABLE_TEMPLATE_DB:-}" != 1 ] && [ -z "${N8N_TEST_TEMPLATE_DB:-}" ] &&
    [ -e node_modules/@n8n/backend-test-utils ]; then
    # Unique per run, and outside the prefix of the test databases the suite's teardown drops.
    export N8N_TEST_TEMPLATE_DB="n8n_template_$$_$RANDOM"
    trap drop_template EXIT
    node "$SCRIPT_DIR/n8n-template-db.cjs" "$N8N_TEST_TEMPLATE_DB" >&2 || exit
  fi
  run_vitest run "${CACHE_OPTS[@]}" --maxWorkers "$MAX_WORKERS" --config "$INTEGRATION_CONFIG" "$@"
)

# run_migration <vitest args...>: cli's migration config, against PostgreSQL or SQLite.
run_migration() (
  local cache_opts=(${CACHE_OPTS[@]+"${CACHE_OPTS[@]}"})
  [ "${VITEST_FS_CACHE:-1}" != 0 ] || cache_opts=()
  if [ "${DB_TYPE:-}" = sqlite ]; then
    unset PGHOST PGPORT PGDATABASE PGUSER PGPASSWORD \
      DB_POSTGRESDB_HOST DB_POSTGRESDB_PORT DB_POSTGRESDB_DATABASE DB_POSTGRESDB_USER DB_POSTGRESDB_PASSWORD \
      DB_POSTGRESDB_SCHEMA DB_TABLE_PREFIX
    export N8N_LOG_LEVEL=silent DB_SQLITE_POOL_SIZE=4 DB_TYPE=sqlite
  else
    export N8N_LOG_LEVEL=silent DB_TYPE=postgresdb DB_POSTGRESDB_USER=postgres PGUSER=postgres \
      DB_POSTGRESDB_DATABASE=n8n DB_POSTGRESDB_SCHEMA=alt_schema DB_TABLE_PREFIX=test_
  fi
  run_vitest run ${cache_opts[@]+"${cache_opts[@]}"} --config vitest.config.migration.ts --coverage.enabled=false "$@"
)

# run_migration_both <vitest args...>: runs PostgreSQL and SQLite migrations concurrently in
# non-recording CI runs, keeping logs ordered and disabling VITEST_FS_CACHE on SQLite.
run_migration_both() (
  local pg_log sqlite_log pg_pid="" sqlite_pid="" pg_rc=0 sqlite_rc=0
  pg_log=$(mktemp "${TMPDIR:-/tmp}/vitest-migrate-pg.XXXXXX")
  sqlite_log=$(mktemp "${TMPDIR:-/tmp}/vitest-migrate-sqlite.XXXXXX")
  cleanup_migrate_logs() {
    [ -z "$pg_pid" ] || kill "$pg_pid" 2>/dev/null || true
    [ -z "$sqlite_pid" ] || kill "$sqlite_pid" 2>/dev/null || true
    rm -f "$pg_log" "$sqlite_log"
  }
  trap cleanup_migrate_logs EXIT INT TERM
  (DB_TYPE=postgresdb run_migration "$@") >"$pg_log" 2>&1 &
  pg_pid=$!
  (VITEST_FS_CACHE=0 DB_TYPE=sqlite DB_SQLITE_POOL_SIZE=4 run_migration "$@") >"$sqlite_log" 2>&1 &
  sqlite_pid=$!
  wait "$pg_pid" || pg_rc=$?
  pg_pid=""
  wait "$sqlite_pid" || sqlite_rc=$?
  sqlite_pid=""
  echo "── [postgresdb] ──"
  cat "$pg_log"
  echo "── [sqlite] ──"
  cat "$sqlite_log"
  [ "$pg_rc" -eq 0 ] || exit "$pg_rc"
  exit "$sqlite_rc"
)

SHARD_OPTS=()
if [ -n "${ENACT_SHARD_INDEX:-}" ] && [ -n "${ENACT_SHARD_TOTAL:-}" ]; then
  SHARD_OPTS=(--shard="${ENACT_SHARD_INDEX}/${ENACT_SHARD_TOTAL}")
elif [ -n "${SHARD:-}" ] && [ -n "${TOTAL_SHARDS:-}" ]; then
  SHARD_OPTS=(--shard="${SHARD}/${TOTAL_SHARDS}")
fi

# No targets: the whole suite, what targeted runs dispatch, the integration tests included
# (enact hands none to an unsharded job's whole-suite run, and gives a sharded one's to its
# first shard; its other shards don't run). A suite with no tests fails, as vitest fails on
# no files. Under `--shard` (SHARD/TOTAL_SHARDS, or a job command naming its shard) a shard
# past the first may draw none, when there are fewer files than shards; the first draws
# one whenever the suite has any.
if [ ${#TARGETS[@]} -eq 0 ]; then
  EMPTY_SHARD=()
  if [ ${#SHARD_OPTS[@]} -gt 0 ] && [ "${ENACT_SHARD_INDEX:-${SHARD:-1}}" -gt 1 ]; then
    EMPTY_SHARD=(--passWithNoTests)
  fi
  if [ "${VITEST_MIGRATION:-}" = both ]; then
    echo "🎯 [enact] No targets specified, running migration test suite (postgresdb + sqlite) ${SHARD_OPTS[*]:-}"
    run_migration_both ${SHARD_OPTS[@]+"${SHARD_OPTS[@]}"} ${EMPTY_SHARD[@]+"${EMPTY_SHARD[@]}"}
    exit
  fi
  if [ "${VITEST_MIGRATION:-}" = 1 ]; then
    echo "🎯 [enact] No targets specified, running migration test suite (${DB_TYPE:-postgresdb}) ${SHARD_OPTS[*]:-}"
    run_migration "${SHARD_OPTS[@]}" "${EMPTY_SHARD[@]}"
    exit
  fi
  echo "🎯 [enact] No targets specified, running unit test suite ${SHARD_OPTS[*]:-}"
  status=0
  N8N_LOG_LEVEL=silent DB_SQLITE_POOL_SIZE=4 DB_TYPE=sqlite run_vitest run "${CACHE_OPTS[@]}" "${SHARD_OPTS[@]}" "${EMPTY_SHARD[@]}" || status=$?
  if [ -n "$INTEGRATION_CONFIG" ]; then
    echo "🎯 [enact] Running integration test suite against PostgreSQL ${SHARD_OPTS[*]:-}"
    run_integration "${SHARD_OPTS[@]}" "${EMPTY_SHARD[@]}" || status=$?
  fi
  exit $status
fi

# The handed targets, each package's in its own run.
status=0
if [ ${#FOREIGN[@]} -gt 0 ]; then
  for pkg in $(for f in "${FOREIGN[@]}"; do package_of "$f"; done | sort -u); do
    in_pkg=()
    for f in "${FOREIGN[@]}"; do
      [ "$(package_of "$f")" = "$pkg" ] && in_pkg+=("${f#"$pkg"/}")
    done
    echo "🎯 [enact] Executing ${#in_pkg[@]} handed test target(s) in ${pkg#"$REPO_ROOT"/}..."
    (cd "$pkg" && VITEST_RUNNER_ARGS= "$SCRIPT_DIR/vitest-runner.sh" "${in_pkg[@]}") || status=$?
  done
  [ ${#OWN[@]} -gt 0 ] || exit $status
fi

# Both kinds run, whichever fails: the exit status is the last failure's. Targets vitest
# runs no file of failed the run before it started (unrun).
if [ ${#UNITS[@]} -gt 0 ]; then
  echo "🎯 [enact] Executing ${#UNITS[@]} unit test target(s)..."
  N8N_LOG_LEVEL=silent DB_SQLITE_POOL_SIZE=4 DB_TYPE=sqlite run_vitest run "${CACHE_OPTS[@]}" --maxWorkers "$MAX_WORKERS" "${UNITS[@]}" || status=$?
fi

if [ ${#INTEGRATIONS[@]} -gt 0 ]; then
  echo "🎯 [enact] Executing ${#INTEGRATIONS[@]} integration test target(s) against PostgreSQL..."
  run_integration "${INTEGRATIONS[@]}" || status=$?
fi

if [ ${#MIGRATIONS[@]} -gt 0 ]; then
  if [ "${VITEST_MIGRATION:-}" = both ]; then
    echo "🎯 [enact] Executing ${#MIGRATIONS[@]} migration test target(s) (postgresdb + sqlite)..."
    run_migration_both "${MIGRATIONS[@]}" || status=$?
  else
    echo "🎯 [enact] Executing ${#MIGRATIONS[@]} migration test target(s) (${DB_TYPE:-postgresdb})..."
    run_migration "${MIGRATIONS[@]}" || status=$?
  fi
fi
exit $status


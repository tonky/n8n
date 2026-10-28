#!/usr/bin/env bash
set -euo pipefail

# vitest-runner.sh: Dispatches targeted tests to unit (SQLite) or integration (Postgres) runner
TARGETS=("$@")

export TZ=UTC
export PGTZ=UTC
export PNPM_MANAGE_PACKAGE_MANAGER_VERSIONS=false
export NODE_COMPILE_CACHE="${NODE_COMPILE_CACHE:-/tmp/.node_compile_cache}"
export NODE_OPTIONS="${NODE_OPTIONS:-} --max-old-space-size=4096"
NPROCS=$(nproc 2>/dev/null || echo 2)
MAX_WORKERS="${MAX_WORKERS:-${ENACT_SHARD_WORKERS:-$NPROCS}}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/pnpm-store.sh"
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

# Node 24's IncomingMessage._destroy detaches [kAbortSignalSocket] with `!== null`; tests
# that `Object.setPrototypeOf(Readable.from(buf), IncomingMessage.prototype)` skip the
# constructor and leave those symbols undefined unless defaulted on the prototype.
HTTP_PRELOAD="$REPO_ROOT/node_modules/.enact-node24-http-preload.cjs"
if [ -d "$REPO_ROOT/node_modules" ] && [ ! -f "$HTTP_PRELOAD" ]; then
  cat > "$HTTP_PRELOAD" <<'EOF'
const { IncomingMessage } = require('node:http');
const sample = new IncomingMessage(null);
for (const sym of Object.getOwnPropertySymbols(sample)) {
  if (!(sym in IncomingMessage.prototype)) IncomingMessage.prototype[sym] = sample[sym];
}
EOF
fi
if [ -f "$HTTP_PRELOAD" ] && [[ "${NODE_OPTIONS:-}" != *".enact-node24-http-preload.cjs"* ]]; then
  export NODE_OPTIONS="${NODE_OPTIONS:-} --require $HTTP_PRELOAD"
fi

# Point @n8n/instance-ai's browser-runtime at enve's Playwright Chromium, and on Linux
# expose its store RUNPATH (libdbus-1.so.3, libxcb.so.1) for node-screenshots' native addon.
if [ -n "${PLAYWRIGHT_BROWSERS_PATH:-}" ] && [ -d "$PLAYWRIGHT_BROWSERS_PATH" ]; then
  for browser in \
    "$PLAYWRIGHT_BROWSERS_PATH"/chromium*/chrome*/headless_shell \
    "$PLAYWRIGHT_BROWSERS_PATH"/chromium*/chrome*/chrome \
    "$PLAYWRIGHT_BROWSERS_PATH"/chromium*/chrome*/*.app/Contents/MacOS/*; do
    if [ -x "$browser" ]; then
      export N8N_EVAL_BROWSER_EXECUTABLE="${N8N_EVAL_BROWSER_EXECUTABLE:-$browser}"
      if [ "$(uname -s)" = Linux ]; then
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

# On linux-arm64, tree-sitter@0.21.1 ships no prebuild and tree-sitter-bash@0.23.3 ships an
# x86-64 ELF binary in prebuilds/linux-arm64; fall back to curlconverter's bundled WASM.
CURL_PARSER="$REPO_ROOT/packages/frontend/editor-ui/node_modules/curlconverter/dist/src/shell/Parser.js"
if [ -f "$CURL_PARSER" ] && [ ! -f "$REPO_ROOT/node_modules/.enact-curlconverter-healed-v1" ]; then
  cat > "$CURL_PARSER" <<'EOF'
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
const require = createRequire(import.meta.url);
let parser;
try {
    const Parser = require("tree-sitter");
    const Bash = require("tree-sitter-bash");
    parser = new Parser();
    parser.setLanguage(Bash);
} catch {
    const WebParser = require("web-tree-sitter");
    await WebParser.init();
    const Bash = await WebParser.Language.load(fileURLToPath(new URL("../../tree-sitter-bash.wasm", import.meta.url)));
    parser = new WebParser();
    parser.setLanguage(Bash);
}
export default parser;
EOF
  touch "$REPO_ROOT/node_modules/.enact-curlconverter-healed-v1" 2>/dev/null || true
fi

# Ensure local node_modules exists for the component: one install however many shards start
# together (the first installs, the others wait and find it done), from the lockfile, failing
# loudly. Unlocked, side-by-side installs into one node_modules collide.
# The lock lives outside the checkout (a lock inside the tree trips tools walking it),
# keyed by the checkout's path. It is the env's flock: the kernel releases it when its holder
# dies, however it dies (a killed Linux job is SIGKILLed, so no cleanup trap runs).
if [ ! -d "node_modules" ] && [ -f "$REPO_ROOT/pnpm-lock.yaml" ]; then
  locks="/tmp/enact-locks-$(id -u)/$(cd "$REPO_ROOT" && pwd -P | cksum | cut -d ' ' -f 1)"
  mkdir -p "$locks"
  exec 9>>"$locks/pnpm-install.flock"
  flock 9
  if [ ! -d "node_modules" ]; then
    echo "📦 [vitest-runner] Local node_modules missing, running pnpm install..."
    # Without the lock's descriptor: a process the install leaves running doesn't hold it.
    (cd "$REPO_ROOT" && pnpm install --frozen-lockfile --prefer-offline) 9>&-
  fi
  exec 9>&-
fi

# The workspace packages: linked where configs and tools resolve them, and built
if [ -d "$REPO_ROOT/packages/@n8n" ]; then
  VITEST_HEALED_SENTINEL="$REPO_ROOT/node_modules/.enact-vitest-healed-v1"
  if [ ! -f "$VITEST_HEALED_SENTINEL" ] || \
     [ ! -e "$REPO_ROOT/node_modules/vitest" ] || \
     [ ! -e "$PWD/node_modules/vitest" ] || \
     { [ -d "$REPO_ROOT/packages/@n8n/vitest-config" ] && [ ! -e "$REPO_ROOT/packages/@n8n/vitest-config/node_modules/vitest" ]; }; then
    # Link all workspace @n8n packages into root node_modules/@n8n so configs and tools resolve them
    mkdir -p "$REPO_ROOT/node_modules/@n8n"
    for pkg in "$REPO_ROOT/packages/@n8n"/*; do
      [ -d "$pkg" ] || continue
      name="${pkg##*/}"
      if [ ! -e "$REPO_ROOT/node_modules/@n8n/$name" ]; then
        ln -sfn "$pkg" "$REPO_ROOT/node_modules/@n8n/$name" 2>/dev/null || true
      fi
    done

    # Self-heal vitest and vite resolution for ESM imports across workspace boundaries
    VITEST_SRC=""
    for candidate in \
      "./node_modules/vitest" \
      "node_modules/vitest" \
      "$PWD/node_modules/vitest" \
      "$REPO_ROOT/node_modules/vitest"; do
      if [ -e "$candidate" ]; then
        VITEST_SRC="$(realpath "$candidate")"
        break
      fi
    done

    if [ -n "$VITEST_SRC" ]; then
      VITEST_PARENT="$(dirname "$VITEST_SRC")"
      VITEST_MOD_NAMES=()
      VITEST_MOD_SRCS=()
      if [ -d "$VITEST_PARENT/@vitest" ]; then
        for vmod in "$VITEST_PARENT/@vitest"/*; do
          if [ -e "$vmod" ]; then
            VITEST_MOD_NAMES+=("${vmod##*/}")
            VITEST_MOD_SRCS+=("$(realpath "$vmod")")
          fi
        done
      fi
      ln -sfn "$VITEST_SRC" "$REPO_ROOT/node_modules/vitest" 2>/dev/null || true
      if [ "${#VITEST_MOD_NAMES[@]}" -gt 0 ]; then
        mkdir -p "$REPO_ROOT/node_modules/@vitest"
        for i in "${!VITEST_MOD_NAMES[@]}"; do
          ln -sfn "${VITEST_MOD_SRCS[$i]}" "$REPO_ROOT/node_modules/@vitest/${VITEST_MOD_NAMES[$i]}" 2>/dev/null || true
        done
      fi
      for p in "$REPO_ROOT"/packages/@n8n/* "$REPO_ROOT"/packages/frontend/@n8n/* "$REPO_ROOT"/packages/frontend/* "$REPO_ROOT"/packages/* "$REPO_ROOT"/packages/modules/*/frontend; do
        if [ -d "$p" ]; then
          mkdir -p "$p/node_modules"
          ln -sfn "$VITEST_SRC" "$p/node_modules/vitest" 2>/dev/null || true
          if [ "${#VITEST_MOD_NAMES[@]}" -gt 0 ]; then
            mkdir -p "$p/node_modules/@vitest"
            for i in "${!VITEST_MOD_NAMES[@]}"; do
              ln -sfn "${VITEST_MOD_SRCS[$i]}" "$p/node_modules/@vitest/${VITEST_MOD_NAMES[$i]}" 2>/dev/null || true
            done
          fi
        fi
      done
      if [ -d "$REPO_ROOT/packages/@n8n/vitest-config" ]; then
        mkdir -p "$REPO_ROOT/packages/@n8n/vitest-config/node_modules/@n8n"
        if [ -d "$REPO_ROOT/packages/@n8n/typescript-config" ]; then
          ln -sfn "../../../typescript-config" "$REPO_ROOT/packages/@n8n/vitest-config/node_modules/@n8n/typescript-config" 2>/dev/null || true
        fi
        ln -sfn "$VITEST_SRC" "$REPO_ROOT/packages/@n8n/vitest-config/node_modules/vitest" 2>/dev/null || true
        if [ "${#VITEST_MOD_NAMES[@]}" -gt 0 ]; then
          mkdir -p "$REPO_ROOT/packages/@n8n/vitest-config/node_modules/@vitest"
          for i in "${!VITEST_MOD_NAMES[@]}"; do
            ln -sfn "${VITEST_MOD_SRCS[$i]}" "$REPO_ROOT/packages/@n8n/vitest-config/node_modules/@vitest/${VITEST_MOD_NAMES[$i]}" 2>/dev/null || true
          done
        fi
      fi
    fi

    VITE_SRC=""
    for candidate in \
      "node_modules/vite" \
      "$REPO_ROOT/packages/cli/node_modules/vite" \
      "$REPO_ROOT/packages/frontend/editor-ui/node_modules/vite" \
      "$REPO_ROOT/node_modules/vite"; do
      if [ -e "$candidate" ]; then
        VITE_SRC="$(realpath "$candidate")"
        break
      fi
    done

    if [ -n "$VITE_SRC" ]; then
      if [ ! -e "$REPO_ROOT/node_modules/vite" ]; then
        ln -sfn "$VITE_SRC" "$REPO_ROOT/node_modules/vite" 2>/dev/null || true
      fi
      if [ -d "$REPO_ROOT/packages/@n8n/vitest-config" ] && [ ! -e "$REPO_ROOT/packages/@n8n/vitest-config/node_modules/vite" ]; then
        ln -sfn "$VITE_SRC" "$REPO_ROOT/packages/@n8n/vitest-config/node_modules/vite" 2>/dev/null || true
      fi
    fi

    # Self-heal vitest-mock-extended resolution for cross-workspace tests
    if [ ! -e "$REPO_ROOT/node_modules/vitest-mock-extended" ]; then
      for candidate in \
        "$REPO_ROOT/packages/@n8n/backend-test-utils/node_modules/vitest-mock-extended" \
        "$REPO_ROOT/packages/cli/node_modules/vitest-mock-extended"; do
        if [ -e "$candidate" ]; then
          ln -sfn "$(realpath "$candidate")" "$REPO_ROOT/node_modules/vitest-mock-extended" 2>/dev/null || true
          break
        fi
      done
    fi

    # Self-heal @testing-library for frontend vitest runs
    if [ -d "$REPO_ROOT/packages/@n8n/vitest-config" ]; then
      for lib in jest-dom vue user-event dom; do
        for candidate in \
          "$REPO_ROOT/packages/frontend/editor-ui/node_modules/@testing-library/$lib" \
          "$REPO_ROOT/packages/@n8n/utils/node_modules/@testing-library/$lib"; do
          if [ -e "$candidate" ]; then
            mkdir -p "$REPO_ROOT/node_modules/@testing-library"
            mkdir -p "$REPO_ROOT/packages/@n8n/vitest-config/node_modules/@testing-library"
            [ -e "$REPO_ROOT/node_modules/@testing-library/$lib" ] || ln -sfn "$(realpath "$candidate")" "$REPO_ROOT/node_modules/@testing-library/$lib" 2>/dev/null || true
            [ -e "$REPO_ROOT/packages/@n8n/vitest-config/node_modules/@testing-library/$lib" ] || ln -sfn "$(realpath "$candidate")" "$REPO_ROOT/packages/@n8n/vitest-config/node_modules/@testing-library/$lib" 2>/dev/null || true
            break
          fi
        done
      done
    fi

    if [ -e "$REPO_ROOT/node_modules/vitest" ]; then
      touch "$VITEST_HEALED_SENTINEL" 2>/dev/null || true
    fi
  fi

  # The workspace packages this one imports from their builds (`<pkg>^...`), with its own
  # when it was handed another package's tests (`../core/...`: they read its build). Every
  # run: turbo builds what changed since its last build (build-workspace-deps.sh); the runs
  # this one starts (a handed package's, footprints.sh's traced run) find them built.
  CURRENT_PKG=$(node -p "require('./package.json').name || ''" 2>/dev/null || true)
  if [ -n "$CURRENT_PKG" ]; then
    filter="${CURRENT_PKG}^..."
    for target in "${TARGETS[@]}"; do
      case "$target" in ../*) filter="${CURRENT_PKG}..." ;; esac
    done
    "$SCRIPT_DIR/build-workspace-deps.sh" "$filter" ||
      { echo "❌ [vitest-runner] building the workspace packages $CURRENT_PKG imports failed" >&2; exit 1; }
    export N8N_WORKSPACE_DEPS_BUILT=1
  fi
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
# Turbo's task logs aren't tests. Exclude the directory itself and its descendants:
# Vitest's CLI patterns add to each config's excludes, for both listing and execution.
DISCOVERY_ARGS=(--exclude '**/.turbo' --exclude '**/.turbo/**')
RUNNER_ARGS=()
[ -z "${VITEST_RUNNER_ARGS:-}" ] || read -ra RUNNER_ARGS <<<"$VITEST_RUNNER_ARGS"

UNITS=()
INTEGRATIONS=()
MIGRATIONS=()

for target in "${OWN[@]}"; do
  clean_target="${target%%::*}"
  # Targets are relative to the package (`test/integration/...`) or to the repository.
  # Only a package with an integration config (cli) runs them on PostgreSQL: core's run
  # under its one config, nodes-base's own config leaves them out (they need testcontainers).
  if [ -f vitest.config.integration.ts ] && { [[ "$clean_target" == *".integration.test.ts" ]] || [[ "/$clean_target" == *"/test/integration/"* ]]; }; then
    INTEGRATIONS+=("$clean_target")
  elif [ -f vitest.config.migration.ts ] && [[ "/$clean_target" == *"/test/migration/"* ]]; then
    MIGRATIONS+=("$clean_target")
  else
    UNITS+=("$clean_target")
  fi
done

# The targets vitest wouldn't run: its config's include/exclude leave them out
# (nodes-base's own config excludes its `*.integration.test.ts`, which need testcontainers),
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
  listed=$(pnpm exec vitest list --filesOnly "${args[@]}" "${RUNNER_ARGS[@]}" "$@" "${DISCOVERY_ARGS[@]}" 2>/dev/null | awk -v d="$PWD/" '{ sub(/^\[[^]]*\] /, ""); print d $0 }') || true
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
    while IFS= read -r t; do missing+=("$t"); done < <(unrun --config vitest.config.integration.ts -- "${INTEGRATIONS[@]}")
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

# Footprints enact asks for (ENACT_FOOTPRINT_DIR: `enact run` recording while it runs,
# `enact trace record`): the wanted test files are traced one by one, the others run as
# here. After the set-up above, so the traced tests find it done and don't record it.
if [ -n "${ENACT_FOOTPRINT_DIR:-}" ] && [ "${DB_TYPE:-}" != sqlite ]; then
  exec "$SCRIPT_DIR/trace/footprints.sh" "$SCRIPT_DIR/vitest-runner.sh" "${TARGETS[@]}"
fi

# Transforms persist across runs (node_modules/.vitest-cache, keyed by each module's
# content and the config: every run still reads the sources it uses, so traces see them):
# halves a test file's start-up. VITEST_FS_CACHE=0 turns it off.
CACHE_OPTS=()
[ "${VITEST_FS_CACHE:-1}" = 0 ] || CACHE_OPTS=(--fsModuleCache)

# The package's vitest, as its `pnpm test` runs it: pnpm sets the environment its scripts
# get (npm_config_user_agent: node-cli's commands pick the package manager they were run with).
# Traced by `enact trace run --attribution` (helpers/trace/trace-files.sh): one forked worker
# per test file, and the reporter saying which modules each loaded.
# A traced run is slower than a plain one (seccomp, one worker per file, shards side by side):
# its hooks get the most any config gives them (nodes-base's integration config, 120 s), not
# the 10 s default cli's unit config keeps for the module-loading `setupTestServer` of its
# `*.api.test.ts`, which a recording otherwise records as failed while plain runs pass.
ATTRIBUTION_ARGS=()
if [ -n "${ENACT_ATTRIBUTION_FILE:-}" ]; then
  ATTRIBUTION_ARGS=(--pool=forks --isolate --hookTimeout=120000 --reporter=default
    "--reporter=$SCRIPT_DIR/trace/vitest-attribution.mjs")
fi
run_vitest() {
  pnpm exec vitest "$@" "${RUNNER_ARGS[@]}" "${ATTRIBUTION_ARGS[@]}" "${DISCOVERY_ARGS[@]}"
}

# run_integration <vitest args...>: cli's integration config, against PostgreSQL.
# Its test files (testDb) clone a template database built once, as upstream's testcontainers
# setup has them, instead of each replaying every migration: workers migrating at once ran
# past the 30s hook timeout. The template is built in this run, so a traced run still reads
# the migrations. N8N_TEST_DISABLE_TEMPLATE_DB=1 (upstream's switch) migrates per file.
run_integration() (
  export N8N_LOG_LEVEL=silent DB_TYPE=postgresdb DB_POSTGRESDB_USER=postgres PGUSER=postgres \
    DB_POSTGRESDB_DATABASE=n8n DB_POSTGRESDB_SCHEMA=alt_schema DB_TABLE_PREFIX=test_
  if [ "${N8N_TEST_DISABLE_TEMPLATE_DB:-}" != 1 ] && [ -z "${N8N_TEST_TEMPLATE_DB:-}" ] &&
    [ -e node_modules/@n8n/backend-test-utils ]; then
    # Unique per run, and outside the prefix of the test databases the suite's teardown drops.
    export N8N_TEST_TEMPLATE_DB="n8n_template_$$_$RANDOM"
    trap drop_template EXIT
    node "$SCRIPT_DIR/n8n-template-db.cjs" "$N8N_TEST_TEMPLATE_DB" >&2 || exit
  fi
  run_vitest run "${CACHE_OPTS[@]}" --maxWorkers "$MAX_WORKERS" --config vitest.config.integration.ts "$@"
)

# run_migration <vitest args...>: cli's migration config, sequentially against PostgreSQL
# or SQLite (when DB_TYPE=sqlite is set by `migrate-sqlite`).
run_migration() (
  if [ "${DB_TYPE:-}" = sqlite ]; then
    unset PGHOST PGPORT PGDATABASE PGUSER PGPASSWORD \
      DB_POSTGRESDB_HOST DB_POSTGRESDB_PORT DB_POSTGRESDB_DATABASE DB_POSTGRESDB_USER DB_POSTGRESDB_PASSWORD
    export N8N_LOG_LEVEL=silent DB_SQLITE_POOL_SIZE=4 DB_TYPE=sqlite
  else
    export N8N_LOG_LEVEL=silent DB_TYPE=postgresdb DB_POSTGRESDB_USER=postgres PGUSER=postgres \
      DB_POSTGRESDB_DATABASE=n8n DB_POSTGRESDB_SCHEMA=alt_schema DB_TABLE_PREFIX=test_
  fi
  run_vitest run "${CACHE_OPTS[@]}" --config vitest.config.migration.ts --coverage.enabled=false "$@"
)

drop_template() {
  local psql=(psql -h "${DB_POSTGRESDB_HOST:-127.0.0.1}" -p "${DB_POSTGRESDB_PORT:?the postgres port (enve.cue)}" -U postgres -d n8n -q)
  "${psql[@]}" -c "UPDATE pg_database SET datistemplate = false WHERE datname = '$N8N_TEST_TEMPLATE_DB'" \
    -c "DROP DATABASE IF EXISTS $N8N_TEST_TEMPLATE_DB" >/dev/null 2>&1 || true
}

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
  if [ "${VITEST_MIGRATION:-}" = 1 ]; then
    echo "🎯 [enact] No targets specified, running migration test suite (${DB_TYPE:-postgresdb}) ${SHARD_OPTS[*]:-}"
    run_migration "${SHARD_OPTS[@]}" "${EMPTY_SHARD[@]}"
    exit
  fi
  echo "🎯 [enact] No targets specified, running unit test suite ${SHARD_OPTS[*]:-}"
  status=0
  N8N_LOG_LEVEL=silent DB_SQLITE_POOL_SIZE=4 DB_TYPE=sqlite run_vitest run "${CACHE_OPTS[@]}" "${SHARD_OPTS[@]}" "${EMPTY_SHARD[@]}" || status=$?
  if [ -f vitest.config.integration.ts ]; then
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
  echo "🎯 [enact] Executing ${#MIGRATIONS[@]} migration test target(s) (${DB_TYPE:-postgresdb})..."
  run_migration "${MIGRATIONS[@]}" || status=$?
fi
exit $status


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
. "$SCRIPT_DIR/pnpm-store.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VITEST_BIN="$REPO_ROOT/packages/cli/node_modules/.bin/vitest"

# The workspace packages: linked where configs and tools resolve them, and built
if [ -d "$REPO_ROOT/packages/@n8n" ]; then
  # Link all workspace @n8n packages into root node_modules/@n8n so configs and tools resolve them
  mkdir -p "$REPO_ROOT/node_modules/@n8n"
  for pkg in "$REPO_ROOT/packages/@n8n"/*; do
    [ -d "$pkg" ] || continue
    name="$(basename "$pkg")"
    if [ ! -e "$REPO_ROOT/node_modules/@n8n/$name" ]; then
      ln -sfn "$pkg" "$REPO_ROOT/node_modules/@n8n/$name" 2>/dev/null || true
    fi
  done

  # What the suite imports and serves from their builds: n8n (the cli run-local-isolated.mjs
  # starts) and the editor among them. Every run: turbo builds what changed since its last
  # build (build-workspace-deps.sh).
  "$SCRIPT_DIR/build-workspace-deps.sh" 'n8n-playwright^...' ||
    { echo "❌ [playwright-runner] building the workspace packages the suite imports failed" >&2; exit 1; }
fi

TARGETS=("$@")

if [ ${#TARGETS[@]} -eq 0 ] && [ -n "${ENACT_TARGETS_FILE:-}" ] && [ -f "$ENACT_TARGETS_FILE" ]; then
  mapfile -t TARGETS < <(rg '\S' "$ENACT_TARGETS_FILE" || true)
fi

if [ -n "${PLAYWRIGHT_BROWSERS_PATH:-}" ]; then
  if compgen -G "$PLAYWRIGHT_BROWSERS_PATH/chromium*" >/dev/null 2>&1; then
    echo "✅ [playwright-runner] Playwright browser already warm in $PLAYWRIGHT_BROWSERS_PATH"
  elif [[ "$PLAYWRIGHT_BROWSERS_PATH" == /nix/store/* || "$PLAYWRIGHT_BROWSERS_PATH" == */enve/store/* ]]; then
    echo "❌ [playwright-runner] Store PLAYWRIGHT_BROWSERS_PATH has no chromium browser: $PLAYWRIGHT_BROWSERS_PATH" >&2
    exit 1
  else
    mkdir -p "$PLAYWRIGHT_BROWSERS_PATH"
    if [ -d "$HOME/.cache/ms-playwright" ] && compgen -G "$HOME/.cache/ms-playwright/chromium*" >/dev/null 2>&1; then
      echo "📦 [playwright-runner] Copying restored browsers from $HOME/.cache/ms-playwright to $PLAYWRIGHT_BROWSERS_PATH..."
      cp -r "$HOME/.cache/ms-playwright/." "$PLAYWRIGHT_BROWSERS_PATH/" 2>/dev/null || true
      echo "✅ [playwright-runner] Playwright browser already warm in $PLAYWRIGHT_BROWSERS_PATH"
    else
      echo "🌐 [playwright-runner] Playwright browser not found in $PLAYWRIGHT_BROWSERS_PATH, installing chromium..."
      # Playwright locks its browsers directory itself (__dirlock), so side-by-side shards wait
      # for one install. A failed install fails the run here, not as a missing browser later.
      pnpm --filter=n8n-playwright exec playwright install chromium
    fi
  fi
fi

PLAYWRIGHT_DIR="$REPO_ROOT/packages/quality/testing/playwright"
# Playwright sizes its workers from os.cpus(): the host's CPUs (14 in a 6-CPU CI container),
# not the shard's. The CPUs enact admitted the shard with size them, at least one
# (e2e-footprints.sh reads the same).
if [ -n "${ENACT_WORKER_CPUS:-}" ]; then
  N8N_PW_WORKERS=${ENACT_WORKER_CPUS%.*}
  [ "${N8N_PW_WORKERS:-0}" -ge 1 ] 2>/dev/null || N8N_PW_WORKERS=1
  export N8N_PW_WORKERS
fi
WORKERS=(${N8N_PW_WORKERS:+--workers "$N8N_PW_WORKERS"})
if [ ${#TARGETS[@]} -eq 0 ]; then
  # The whole suite: its vitest tests, then every e2e spec (run-local-isolated.mjs given no
  # path runs tests/e2e).
  echo "🎯 [enact:playwright] Running the whole suite: unit tests, then every e2e spec..."
  "$VITEST_BIN" run --config "$PLAYWRIGHT_DIR/vitest.config.ts"
  exec node --import "$SCRIPT_DIR/n8n-ready.mjs" "$PLAYWRIGHT_DIR/scripts/run-local-isolated.mjs" "${WORKERS[@]}"
fi

SPECS=()
UNITS=()
UNRUN=()

# A target the runs below would leave out fails the run before any test runs: given it
# beside others, vitest and Playwright would run only the others and pass.
# run-local-isolated.mjs runs the e2e project, whose specs are tests/e2e's; the other
# projects' specs are the target scope's not_run.
for target in "${TARGETS[@]}"; do
  if [[ "$target" == *".spec.ts" ]]; then
    if [[ "${target#./}" == tests/e2e/* ]]; then SPECS+=("$target"); else UNRUN+=("$target"); fi
  else
    UNITS+=("$target")
  fi
done
if [ ${#UNITS[@]} -gt 0 ]; then
  # The unit targets vitest.config.ts's include lists (`vitest list`: no test runs).
  listed=$("$VITEST_BIN" list --filesOnly "${UNITS[@]}" 2>/dev/null) || true
  for target in "${UNITS[@]}"; do
    [[ $listed == *"${target#./}"* ]] || UNRUN+=("$target")
  done
fi
if [ ${#UNRUN[@]} -gt 0 ]; then
  echo "❌ [playwright-runner] ${#UNRUN[@]} target(s) no run here runs (not a tests/e2e spec, or a file vitest.config.ts leaves out): ${UNRUN[*]}" >&2
  exit 1
fi

if [ ${#UNITS[@]} -gt 0 ]; then
  echo "🎯 [enact:playwright] Executing ${#UNITS[@]} unit/framework test target(s)..."
  "$VITEST_BIN" run "${UNITS[@]}"
fi

if [ ${#SPECS[@]} -gt 0 ]; then
  echo "🎯 [enact:playwright] Executing ${#SPECS[@]} Playwright E2E spec(s) with isolated environment..."
  # Footprints enact asks for (ENACT_FOOTPRINT_DIR: `enact trace record`, `enact run`
  # recording): each wanted spec alone, recorded (trace/e2e-footprints.sh).
  if [ -n "${ENACT_FOOTPRINT_DIR:-}" ]; then
    "$SCRIPT_DIR/trace/e2e-footprints.sh" "${SPECS[@]}"
  else
    # The specs grouped by the n8n env each declares (pw-spec-env.mjs): each group on an n8n
    # of its own, started with that env; every group runs, the first failure fails the run.
    status=0
    while IFS=$'\t' read -r -a group; do
      N8N_TEST_ENV="${group[0]}" node --import "$SCRIPT_DIR/n8n-ready.mjs" \
        "$PLAYWRIGHT_DIR/scripts/run-local-isolated.mjs" "${WORKERS[@]}" "${group[@]:1}" ||
        { s=$?; [ "$status" -ne 0 ] || status=$s; }
    done < <(node "$SCRIPT_DIR/pw-spec-env.mjs" "$PLAYWRIGHT_DIR" "${SPECS[@]}")
    exit "$status"
  fi
fi

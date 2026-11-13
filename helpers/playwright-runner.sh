#!/usr/bin/env bash
set -eo pipefail

export TZ=UTC
export PGTZ=UTC
export NODE_COMPILE_CACHE="${NODE_COMPILE_CACHE:-/tmp/.node_compile_cache}"
export NODE_OPTIONS="${NODE_OPTIONS:-} --max-old-space-size=4096"
export PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-/tmp/.cache/ms-playwright}"
export PNPM_MANAGE_PACKAGE_MANAGER_VERSIONS=false
export N8N_ENCRYPTION_KEY="${N8N_ENCRYPTION_KEY:-e2e-test-encryption-key-n8n}"
export N8N_GIT_COMMIT="${N8N_GIT_COMMIT:-${GITHUB_SHA:-$(git rev-parse HEAD 2>/dev/null || echo unknown)}}"
# Isolated Playwright runner uses local throwaway SQLite instance per spec
export DB_TYPE=sqlite
unset DB_POSTGRESDB_HOST DB_POSTGRESDB_PORT DB_POSTGRESDB_DATABASE DB_POSTGRESDB_USER DB_POSTGRESDB_PASSWORD

# Find repo root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VITEST_BIN="$REPO_ROOT/packages/cli/node_modules/.bin/vitest"

if [ "${1:-}" = "--ensure-browsers" ]; then
  if [ -n "${PLAYWRIGHT_BROWSERS_PATH:-}" ] && [ "$(uname -s)" = "Linux" ]; then
    for browser_bin in \
      "$PLAYWRIGHT_BROWSERS_PATH"/chromium*/chrome*/chrome-headless-shell \
      "$PLAYWRIGHT_BROWSERS_PATH"/chromium*/chrome*/headless_shell \
      "$PLAYWRIGHT_BROWSERS_PATH"/chromium*/chrome*/chrome; do
      if [ -x "$browser_bin" ]; then
        if ! "$browser_bin" --version >/dev/null 2>&1; then
          echo "📦 [playwright-runner] Pulling Nix store RUNPATH closure for $browser_bin..." >&2
          enve cache pull "$REPO_ROOT/enve.lock" \
            --cache "${ENACT_R2_BUCKET:-https://pub-30fd937eb7634039b8c49d49bfec91a9.r2.dev}" \
            -j 16 >&2 || true
        fi
        break
      fi
    done
  fi
  exit 0
fi

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
    if [ "$(uname -s)" = "Linux" ]; then
      for browser_bin in \
        "$PLAYWRIGHT_BROWSERS_PATH"/chromium*/chrome*/chrome-headless-shell \
        "$PLAYWRIGHT_BROWSERS_PATH"/chromium*/chrome*/headless_shell \
        "$PLAYWRIGHT_BROWSERS_PATH"/chromium*/chrome*/chrome; do
        if [ -x "$browser_bin" ]; then
          if ! "$browser_bin" --version >/dev/null 2>&1; then
            echo "📦 [playwright-runner] Pulling Nix store RUNPATH closure for $browser_bin..." >&2
            enve cache pull "$REPO_ROOT/enve.lock" \
              --cache "${ENACT_R2_BUCKET:-https://pub-30fd937eb7634039b8c49d49bfec91a9.r2.dev}" \
              -j 16 >&2 || true
          fi
          break
        fi
      done
    fi
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
# run-local-isolated owns one backend shared by this invocation's tests. A worker
# replacement must reset it before retry hooks; concurrent workers cannot share it.
# This limits test concurrency, not the admitted job's CPU or memory allocation.
export N8N_PW_WORKERS=1
WORKERS=(--workers 1)
if [ ${#TARGETS[@]} -eq 0 ]; then
  echo "🎯 [enact:playwright] Running the whole suite: unit tests, then every e2e spec..."
  "$VITEST_BIN" run --config "$PLAYWRIGHT_DIR/vitest.config.ts"
  shopt -s globstar nullglob
  for spec in "$PLAYWRIGHT_DIR"/tests/e2e/**/*.spec.ts; do TARGETS+=("${spec#"$PLAYWRIGHT_DIR"/}"); done
  [ ${#TARGETS[@]} -gt 0 ] || { echo "playwright-runner: whole suite contains no e2e specs" >&2; exit 1; }
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
  export ENACT_PW_BACKEND=shared
  # One public CA handoff before fixtures clear/reset MockServer expectations. Children
  # reuse this job-private file; per-spec resolver calls must never fetch it again.
  unset ENACT_NATIVE_PROXY_ENV_FILE
  if [ -n "${ENACT_NATIVE_PROXY_URL:-}" ]; then
    proxy_dir=$(mktemp -d "${TMPDIR:-/tmp}/enact-pw-proxy.XXXXXX")
    trap 'rm -rf -- "$proxy_dir"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    node "$SCRIPT_DIR/native-proxy.mjs" prepare "$ENACT_NATIVE_PROXY_URL" "$proxy_dir" > "$proxy_dir/environment.json"
    export ENACT_NATIVE_PROXY_ENV_FILE="$proxy_dir/environment.json"
  fi
  echo "🎯 [enact:playwright] Executing ${#SPECS[@]} Playwright E2E spec(s) with isolated environment..."
  # Footprints enact asks for (ENACT_FOOTPRINT_DIR: `enact reach record`, `enact run`
  # recording): each wanted spec alone, recorded (trace/e2e-footprints.sh).
  if [ -n "${ENACT_FOOTPRINT_DIR:-}" ]; then
    "$SCRIPT_DIR/trace/e2e-footprints.sh" "${SPECS[@]}"
  else
    # The specs grouped by the n8n env each declares (pw-spec-env.mjs): each group on an n8n
    # of its own, started with that env; every group runs, the first failure fails the run.
    # A group's second field is its workers: `1` for specs resetting the database, else `-`.
    status=0
    groups=$(node "$SCRIPT_DIR/pw-spec-env.mjs" "$PLAYWRIGHT_DIR" "${SPECS[@]}") || exit "$?"
    [ -n "$groups" ] || { echo "playwright-runner: no groups for requested specs" >&2; exit 1; }
    while IFS=$'\t' read -r -a group; do
      group_workers=("${WORKERS[@]}")
      [ "${group[1]}" = - ] || group_workers=(--workers "${group[1]}")
      N8N_TEST_ENV="${group[0]}" node --import "$SCRIPT_DIR/n8n-ready.mjs" \
        "$PLAYWRIGHT_DIR/scripts/run-local-isolated.mjs" "${group_workers[@]}" "${group[@]:2}" ||
        { s=$?; [ "$status" -ne 0 ] || status=$s; }
    done <<< "$groups"
    exit "$status"
  fi
fi

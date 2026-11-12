#!/usr/bin/env bash
# ==============================================================================
# build-workspace-deps.sh [--checked] <turbo filter...> - Builds workspace packages when their sources changed
# ==============================================================================
# Standalone callers targeting declared `#Job.outputs` producers (`n8n...`, `n8n-playwright^...`,
# `@n8n/db`) materialize them through `enact helper ensure-outputs` (a cone without the producer's
# root takes restored outputs or builds with turbo). Dynamic per-package filters and `--checked`
# builds serialize `pnpm turbo run` under `enact helper lock workspace-build`.
# N8N_WORKSPACE_DEPS_BUILT=1 skips it when a caller already built up front.
# ==============================================================================
set -euo pipefail
export TURBO_TELEMETRY_DISABLED=1
export VITE_CONFIG_NATIVE_IGNORE_WARNING=true
if [ -n "${ENACT_HOST_CACHE:-}" ] && [ -d "$ENACT_HOST_CACHE/repo" ] && [ -w "$ENACT_HOST_CACHE/repo" ]; then
  mkdir -p "$ENACT_HOST_CACHE/repo/turbo" 2>/dev/null || true
  export TURBO_CACHE_DIR="${TURBO_CACHE_DIR:-$ENACT_HOST_CACHE/repo/turbo}"
fi
[ "${N8N_WORKSPACE_DEPS_BUILT:-}" = 1 ] && exit 0
task=build:unchecked
if [ "${1:-}" = --checked ]; then task=build; shift; fi
[ $# -gt 0 ] || { echo "usage: build-workspace-deps.sh [--checked] <turbo filter...>" >&2; exit 64; }

cd "$(dirname "${BASH_SOURCE[0]}")/.."
stamp_dir=""
if [ "${GITHUB_ACTIONS:-}" = true ] && [ -n "${RUNNER_TEMP:-}" ] && [ -z "$(git status --porcelain --untracked-files=no 2>/dev/null || echo dirty)" ]; then
  head_sha="$(git rev-parse HEAD 2>/dev/null || true)"
  if [ -n "$head_sha" ]; then
    root_key="$(printf '%s' "$PWD" | cksum | awk '{print $1}')"
    stamp_dir="$RUNNER_TEMP/enact-n8n-ws-build-$head_sha-$root_key"
    mkdir -p "$stamp_dir"
  fi
fi
if [ -f packages/@n8n/db/scripts/generate-migration-index.mjs ] && { [ -z "$stamp_dir" ] || [ ! -f "$stamp_dir/migration-indexes.done" ]; }; then
  node -e '
    const fs = require("node:fs");
    const orig = fs.writeFileSync;
    fs.writeFileSync = (p, data, ...rest) => {
      try { if (fs.readFileSync(p, "utf8") === data) return; } catch {}
      return orig(p, data, ...rest);
    };
    require("node:module").syncBuiltinESMExports();
    import("./packages/@n8n/db/scripts/generate-migration-index.mjs").then(m => m.generateMigrationIndexes());
  '
  [ -z "$stamp_dir" ] || : > "$stamp_dir/migration-indexes.done"
fi
if [ -d node_modules ] && [ -d packages/@n8n ] && { [ -z "$stamp_dir" ] || [ ! -f "$stamp_dir/symlinks.done" ]; }; then
  mkdir -p node_modules/@n8n
  for pkg in packages/@n8n/*; do
    [ -d "$pkg" ] || continue
    name="${pkg##*/}"
    [ -e "node_modules/@n8n/$name" ] || ln -sfn "../../$pkg" "node_modules/@n8n/$name" 2>/dev/null || true
  done
  if [ ! -f packages/frontend/editor-ui/index.js ]; then
    if [ ! -f node_modules/n8n-editor-ui/index.js ]; then
      mkdir -p node_modules/n8n-editor-ui
      printf '{"name":"n8n-editor-ui","main":"index.js"}\n' > node_modules/n8n-editor-ui/package.json 2>/dev/null || true
      : > node_modules/n8n-editor-ui/index.js 2>/dev/null || true
    fi
    if [ -d packages/cli/node_modules ] && [ ! -e packages/cli/node_modules/n8n-editor-ui/index.js ]; then
      ln -sfn "$PWD/node_modules/n8n-editor-ui" packages/cli/node_modules/n8n-editor-ui 2>/dev/null || true
    fi
  fi
  [ -z "$stamp_dir" ] || : > "$stamp_dir/symlinks.done"
fi
enact="${ENACT_EXE:-${ENACT_BIN:-$(command -v enact || true)}}"
[ -n "$enact" ] || { echo "build-workspace-deps.sh: enact not found (set ENACT_EXE, ENACT_BIN, or put enact on PATH)" >&2; exit 2; }
if [ "$task" = "build:unchecked" ] && [ -d .enact ]; then
  extra_ok=1
  for extra in "${@:2}"; do
    case "$extra" in
      @n8n/eslint-config | @n8n/oxlint-config | @n8n/stylelint-config) ;;
      *) extra_ok=0; break ;;
    esac
  done
  if [ "$extra_ok" -eq 1 ]; then
    case "$1" in
      n8n-playwright^... | @n8n/efficiency^...)
        if [ "${ENACT_COMPONENT:-}:${ENACT_JOB:-}" != "playwright:build" ]; then
          if [ -d packages/@n8n/db ] && [ ! -f packages/@n8n/db/dist/index.d.ts ] && [ "${ENACT_COMPONENT:-}:${ENACT_JOB:-}" != "@n8n/db:build" ]; then
            "$enact" helper ensure-outputs @n8n/db:build || true
          fi
          if [ "${ENACT_JOB:-}" = "lint" ] || [ "${ENACT_JOB:-}" = "typecheck" ]; then
            [ -f .enact/state/outputs/playwright--build.key ] && exit 0
            set -- \
              '@n8n/db^...' \
              '@n8n/api-types...' \
              'n8n-core...' \
              'n8n-containers...' \
              '@n8n/playwright-janitor...' \
              '@n8n/test-impact...' \
              '@n8n/workflow-sdk...' \
              '@n8n/eslint-config...' \
              '@n8n/oxlint-config...' \
              "${@:2}"
          else
            [ ! -d packages/quality/testing/playwright ] || exec "$enact" helper ensure-outputs playwright:build
            "$enact" helper ensure-outputs playwright:build 2>/dev/null && exit 0
          fi
        fi
        ;;
      n8n... | @n8n/performance^...)
        if [ $# -eq 1 ] && [ "${ENACT_COMPONENT:-}:${ENACT_JOB:-}" != "playwright:build" ]; then
          [ ! -d packages/quality/testing/playwright ] || exec "$enact" helper ensure-outputs playwright:build
          # A cone without playwright's root (cli's or @n8n/performance's) can't run its producer:
          # restored outputs serve, else turbo builds `n8n...` / `@n8n/performance^...` below.
          "$enact" helper ensure-outputs playwright:build 2>/dev/null && exit 0
        fi
        ;;
      @n8n/db)
        if [ $# -eq 1 ] && [ "${ENACT_COMPONENT:-}:${ENACT_JOB:-}" != "@n8n/db:build" ]; then
          exec "$enact" helper ensure-outputs @n8n/db:build
        fi
        ;;
    esac
  fi
fi
if [ -n "$stamp_dir" ]; then
  missing=0
  for filter in "$@"; do
    fk="$(printf '%s\0%s' "$task" "$filter" | cksum | awk '{print $1 "-" $2}')"
    [ -f "$stamp_dir/filter-$fk.done" ] || { missing=1; break; }
  done
  [ "$missing" -eq 0 ] && exit 0
  filters=()
  for filter in "$@"; do filters+=("--filter=$filter"); done
  "$enact" helper lock workspace-build -- bash -e -c '
    stamp_dir="$1"; task="$2"; shift 2
    missing=0
    for filter in "$@"; do
      fk="$(printf "%s\0%s" "$task" "$filter" | cksum | awk "{print \$1 \"-\" \$2}")"
      [ -f "$stamp_dir/filter-$fk.done" ] || { missing=1; break; }
    done
    [ "$missing" -eq 0 ] && exit 0
    filters=()
    for filter in "$@"; do filters+=("--filter=$filter"); done
    pnpm turbo run "$task" "${filters[@]}" --output-logs=errors-only
    for filter in "$@"; do
      fk="$(printf "%s\0%s" "$task" "$filter" | cksum | awk "{print \$1 \"-\" \$2}")"
      : > "$stamp_dir/filter-$fk.done"
    done
  ' _ "$stamp_dir" "$task" "$@"
  exit 0
fi
filters=()
for filter in "$@"; do filters+=("--filter=$filter"); done
exec "$enact" helper lock workspace-build -- \
  pnpm turbo run "$task" "${filters[@]}" --output-logs=errors-only

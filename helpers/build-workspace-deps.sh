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
  [ -z "$stamp_dir" ] || : > "$stamp_dir/symlinks.done"
fi
enact="${ENACT_EXE:-${ENACT_BIN:-$(command -v enact || true)}}"
[ -n "$enact" ] || { echo "build-workspace-deps.sh: enact not found (set ENACT_EXE, ENACT_BIN, or put enact on PATH)" >&2; exit 2; }
if [ "$task" = "build:unchecked" ] && [ $# -eq 1 ] && [ -d .enact ]; then
  case "$1" in
    n8n-playwright^... | n8n...)
      if [ "${ENACT_COMPONENT:-}:${ENACT_JOB:-}" != "playwright:build" ]; then
        [ ! -d packages/quality/testing/playwright ] || exec "$enact" helper ensure-outputs playwright:build
        # A cone without playwright's root (cli's) can't run its producer: restored outputs
        # serve, else turbo builds `n8n...` below.
        "$enact" helper ensure-outputs playwright:build 2>/dev/null && exit 0
      fi
      ;;
    @n8n/db)
      if [ "${ENACT_COMPONENT:-}:${ENACT_JOB:-}" != "@n8n/db:build" ]; then
        exec "$enact" helper ensure-outputs @n8n/db:build
      fi
      ;;
  esac
fi
if [ -n "$stamp_dir" ]; then
  filter_key="$(printf '%s\0%s' "$task" "$*" | cksum | awk '{print $1 "-" $2}')"
  stamp_file="$stamp_dir/turbo-$filter_key.done"
  [ -f "$stamp_file" ] && exit 0
  filters=()
  for filter in "$@"; do filters+=("--filter=$filter"); done
  "$enact" helper lock workspace-build -- \
    pnpm turbo run "$task" "${filters[@]}" --output-logs=errors-only
  : > "$stamp_file"
  exit 0
fi
filters=()
for filter in "$@"; do filters+=("--filter=$filter"); done
exec "$enact" helper lock workspace-build -- \
  pnpm turbo run "$task" "${filters[@]}" --output-logs=errors-only

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
turbo_flags=()
only_build=0
upstream_key_file=""
while [ $# -gt 0 ]; do
  case "$1" in
    --checked) task=build; shift ;;
    --only) only_build=1; turbo_flags+=("$1"); shift ;;
    --upstream-key-file=*) upstream_key_file="${1#--upstream-key-file=}"; shift ;;
    *) break ;;
  esac
done
[ $# -gt 0 ] || { echo "usage: build-workspace-deps.sh [--checked] <turbo filter...>" >&2; exit 64; }

cd "$(dirname "${BASH_SOURCE[0]}")/.."
unset ENACT_UPSTREAM_OUTPUT_KEY
if [ -n "$upstream_key_file" ]; then
  [ -s "$upstream_key_file" ] || { echo "build-workspace-deps.sh: required producer stamp missing: $upstream_key_file" >&2; exit 2; }
  # Turbo's global file globs ignore .enact/state; its explicit globalEnv contract
  # carries the restored producer key while --only keeps its tasks out of this run.
  export ENACT_UPSTREAM_OUTPUT_KEY="$(cat "$upstream_key_file")"
fi
stamp_dir=""
if [ ${#turbo_flags[@]} -eq 0 ] && [ "${GITHUB_ACTIONS:-}" = true ] && [ -n "${RUNNER_TEMP:-}" ] && [ -z "$(git status --porcelain --untracked-files=no 2>/dev/null || echo dirty)" ]; then
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
      n8n...)
        if [ $# -eq 1 ] && [ "${ENACT_COMPONENT:-}:${ENACT_JOB:-}" != "cli:build" ] && [ "${ENACT_COMPONENT:-}:${ENACT_JOB:-}" != "playwright:build" ]; then
          exec "$enact" helper ensure-outputs cli:build
        fi
        ;;
      @n8n/performance^...)
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
if [ "$only_build" -eq 1 ]; then
  "$enact" helper lock workspace-build -- \
    pnpm turbo run "$task" "${turbo_flags[@]}" "${filters[@]}" --output-logs=errors-only
  # pnpm links workspace bins during install. A consumer installing after a dist
  # restore must not change the executable identity the producer publishes.
  # Resolve the selected workspace set once; never chmod source scripts or other packages.
  pnpm ls -r --depth -1 --json "${filters[@]}" | node -e '
    const fs = require("node:fs");
    const path = require("node:path");
    const root = fs.realpathSync(process.cwd());
    const packages = JSON.parse(fs.readFileSync(0, "utf8"));
    if (!Array.isArray(packages)) throw new Error("expected workspace package metadata");
    for (const entry of packages) {
      const directory = fs.realpathSync(entry.path);
      if (directory !== root && !directory.startsWith(root + path.sep)) {
        throw new Error("workspace package escapes checkout: " + entry.path);
      }
      const manifest = JSON.parse(fs.readFileSync(path.join(directory, "package.json"), "utf8"));
      const bins = typeof manifest.bin === "string" ? [manifest.bin] : Object.values(manifest.bin || {});
      for (const bin of bins) {
        if (typeof bin !== "string" || path.isAbsolute(bin) || bin.split(/[\\/]/).includes("..")) {
          throw new Error("workspace bin escapes package: " + bin);
        }
        const relative = path.normalize(bin);
        if (!relative.startsWith("dist/")) continue;
        let target = directory;
        let info;
        for (const part of relative.split("/")) {
          target = path.join(target, part);
          try { info = fs.lstatSync(target); }
          catch { throw new Error("required generated workspace bin is missing: " + target); }
          if (info.isSymbolicLink()) throw new Error("generated workspace bin crosses a symlink: " + target);
        }
        if (!info.isFile()) throw new Error("generated workspace bin is not regular: " + target);
        if ((info.mode & 0o111) !== 0o111) fs.chmodSync(target, (info.mode & 0o7777) | 0o111);
      }
    }
  '
  exit 0
fi
exec "$enact" helper lock workspace-build -- \
  pnpm turbo run "$task" "${turbo_flags[@]}" "${filters[@]}" --output-logs=errors-only

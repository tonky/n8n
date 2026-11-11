#!/usr/bin/env bash
# ==============================================================================
# typecheck-runner.sh [--declarations] <pkg_dir> <pkg_name>
# ==============================================================================
# Restores and archives per-package `.tsbuildinfo` files inside `$REPO_ROOT/.turbo/tsbuildinfo`
# so GHA's rolling `node_build` cache (`paths: [".turbo"]`) accelerates incremental
# `tsc`, `tsgo`, and `vue-tsc` runs across commits.
# ==============================================================================
set -euo pipefail

export PNPM_MANAGE_PACKAGE_MANAGER_VERSIONS=false
export TURBO_TELEMETRY_DISABLED=1
export VITE_CONFIG_NATIVE_IGNORE_WARNING=true
export NODE_COMPILE_CACHE="${NODE_COMPILE_CACHE:-/tmp/.node_compile_cache}"

check_declarations=0
if [ "${1:-}" = "--declarations" ]; then
  check_declarations=1
  shift
fi

[ $# -eq 2 ] || { echo "usage: typecheck-runner.sh [--declarations] <pkg_dir> <pkg_name>" >&2; exit 64; }
raw_pkg_dir="${1%/}"
pkg_name="$2"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
[ -n "$raw_pkg_dir" ] || raw_pkg_dir="."
case "$raw_pkg_dir" in
  . | ./* | .. | ../* | /*)
    [ -d "$raw_pkg_dir" ] || { echo "typecheck-runner.sh: package directory not found: $raw_pkg_dir" >&2; exit 64; }
    ABS_PKG_DIR="$(cd "$raw_pkg_dir" && pwd -P)"
    ;;
  *)
    if [ -d "$REPO_ROOT/$raw_pkg_dir" ]; then
      ABS_PKG_DIR="$(cd "$REPO_ROOT/$raw_pkg_dir" && pwd -P)"
    elif [ -d "$raw_pkg_dir" ]; then
      ABS_PKG_DIR="$(cd "$raw_pkg_dir" && pwd -P)"
    else
      echo "typecheck-runner.sh: package directory not found: $raw_pkg_dir" >&2
      exit 64
    fi
    ;;
esac
if [ "$ABS_PKG_DIR" = "$REPO_ROOT" ]; then
  pkg_dir="."
  PKG_SLUG="root"
else
  pkg_dir="${ABS_PKG_DIR#"$REPO_ROOT"/}"
  PKG_SLUG="${pkg_dir//\//__}"
fi
CACHE_BASE="$REPO_ROOT/.turbo/tsbuildinfo/$PKG_SLUG"

copy_tsbuildinfo() {
  local src_dir="$1"
  local dst_dir="$2"
  [ -d "$src_dir" ] || return 0
  shopt -s nullglob
  local files=("$src_dir"/*.tsbuildinfo)
  shopt -u nullglob
  [ "${#files[@]}" -gt 0 ] || return 0
  mkdir -p "$dst_dir"
  cp -p "${files[@]}" "$dst_dir/"
}

"$SCRIPT_DIR/build-workspace-deps.sh" "${pkg_name}^..."

copy_tsbuildinfo "$CACHE_BASE/dot-turbo" "$ABS_PKG_DIR/.turbo"
copy_tsbuildinfo "$CACHE_BASE/dist" "$ABS_PKG_DIR/dist"
copy_tsbuildinfo "$CACHE_BASE/evaluations" "$ABS_PKG_DIR/evaluations"
copy_tsbuildinfo "$CACHE_BASE/root" "$ABS_PKG_DIR"

(
  cd "$REPO_ROOT"
  pnpm turbo run --only --env-mode=loose typecheck "--filter=$pkg_name" --output-logs=errors-only
)

copy_tsbuildinfo "$ABS_PKG_DIR/.turbo" "$CACHE_BASE/dot-turbo"
copy_tsbuildinfo "$ABS_PKG_DIR/dist" "$CACHE_BASE/dist"
copy_tsbuildinfo "$ABS_PKG_DIR/evaluations" "$CACHE_BASE/evaluations"
copy_tsbuildinfo "$ABS_PKG_DIR" "$CACHE_BASE/root"

if [ "$check_declarations" -eq 1 ]; then
  RELEASE=true "$SCRIPT_DIR/build-workspace-deps.sh" --checked "$pkg_name"
  test -f "$ABS_PKG_DIR/dist/index.d.ts"
fi

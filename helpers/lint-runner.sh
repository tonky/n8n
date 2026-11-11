#!/usr/bin/env bash
# ==============================================================================
# lint-runner.sh [--styles] [--format] <pkg_dir> <pkg_name> <file...>
# ==============================================================================
# Runs file-scoped lint, stylelint, and format checks for changed files inside a
# workspace package, falling back to full Turbo package tasks on whole-package
# runs (`.`) or config/script changes. Builds workspace dependencies only when
# code linters (`oxlint`, `eslint`) or whole-package tasks actually run.
# ==============================================================================
set -euo pipefail

export PNPM_MANAGE_PACKAGE_MANAGER_VERSIONS=false
export TURBO_TELEMETRY_DISABLED=1
export VITE_CONFIG_NATIVE_IGNORE_WARNING=true
export NODE_COMPILE_CACHE="${NODE_COMPILE_CACHE:-/tmp/.node_compile_cache}"

run_styles=0
run_format=0
while [ $# -gt 0 ]; do
  case "$1" in
    --styles) run_styles=1; shift ;;
    --format) run_format=1; shift ;;
    --) shift; break ;;
    -*) echo "lint-runner.sh: unknown option: $1" >&2; exit 64 ;;
    *) break ;;
  esac
done

[ $# -ge 2 ] || { echo "usage: lint-runner.sh [--styles] [--format] <pkg_dir> <pkg_name> <file...>" >&2; exit 64; }
pkg_dir="${1%/}"
pkg_name="$2"
shift 2

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ABS_PKG_DIR="$REPO_ROOT/$pkg_dir"
PKG_SLUG="${pkg_dir//\//__}"

build_lint_deps() {
  local dep_filter="${pkg_name}^..."
  [ "$pkg_name" = "n8n-nodes-base" ] && dep_filter="n8n-nodes-base..."
  local extra=(@n8n/eslint-config @n8n/oxlint-config)
  [ "$run_styles" -eq 1 ] && extra+=(@n8n/stylelint-config)
  "$SCRIPT_DIR/build-workspace-deps.sh" "$dep_filter" "${extra[@]}"
}

local_bin() {
  local name="$1"
  local candidate
  for candidate in \
    "$ABS_PKG_DIR/node_modules/.bin/$name" \
    "$REPO_ROOT/node_modules/.bin/$name" \
    "$REPO_ROOT/node_modules/.pnpm/node_modules/.bin/$name" \
    "$REPO_ROOT/packages/@n8n/oxlint-config/node_modules/.bin/$name"; do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  command -v "$name"
}

whole_pkg=0
[ $# -eq 0 ] && whole_pkg=1
rel_files=()
for raw in "$@"; do
  if [ "$raw" = "." ]; then
    whole_pkg=1
    break
  fi
  rel="${raw#./}"
  if [[ "$rel" == "${pkg_dir}/"* ]] && [ ! -e "$ABS_PKG_DIR/$rel" ] && [ -e "$REPO_ROOT/$rel" ]; then
    rel="${rel#"${pkg_dir}/"}"
  fi
  if [ "$rel" = "." ]; then
    whole_pkg=1
    break
  fi
  if [ "$rel" = ".." ] || [[ "$rel" == ../* ]]; then
    continue
  fi
  base="${rel##*/}"
  case "$rel" in
    package.json | */package.json | scripts/*)
      whole_pkg=1
      break
      ;;
  esac
  case "$base" in
    tsconfig*.json | *eslint* | *oxlint* | *stylelint* | *prettier* | biome*)
      whole_pkg=1
      break
      ;;
  esac
  if [ -f "$ABS_PKG_DIR/$rel" ]; then
    rel_files+=("$rel")
  fi
done

if [ "$whole_pkg" -eq 1 ]; then
  build_lint_deps
  turbo_tasks=(lint)
  [ "$run_styles" -eq 1 ] && turbo_tasks+=(lint:styles)
  [ "$run_format" -eq 1 ] && turbo_tasks+=(format:check)
  cd "$REPO_ROOT"
  exec pnpm turbo run --only --env-mode=loose "${turbo_tasks[@]}" "--filter=$pkg_name" --output-logs=errors-only --concurrency=2
fi

[ "${#rel_files[@]}" -gt 0 ] || exit 0

plan_output="$(node - "$ABS_PKG_DIR/package.json" "$run_styles" "$run_format" "${rel_files[@]}" <<'NODE'
const fs = require('node:fs');
const [pkgPath, runStylesArg, runFormatArg, ...files] = process.argv.slice(2);
const runStyles = runStylesArg === '1';
const runFormat = runFormatArg === '1';
const pkg = JSON.parse(fs.readFileSync(pkgPath, 'utf8'));
const scripts = pkg.scripts || {};
const lint = scripts.lint || '';
const fmt = scripts['format:check'] || '';
const styles = scripts['lint:styles'] || '';

const CODE_RE = /\.(?:[cm]?[jt]sx?|vue)$/;
const STYLE_RE = /\.(?:scss|sass|vue)$/;

function cleanScope(tok) {
  const trimmed = tok.replace(/^['"]|['"]$/g, '').replace(/\/+$/, '');
  return trimmed || '.';
}

function extractToolScopes(script, tool, afterSubcmd) {
  for (const rawSeg of script.split('&&')) {
    const tokens = rawSeg.trim().split(/\s+/).filter(Boolean);
    const idx = tokens.indexOf(tool);
    if (idx === -1) continue;
    let start = idx + 1;
    if (afterSubcmd && tokens[start] === afterSubcmd) start += 1;
    const scopes = [];
    for (let i = start; i < tokens.length; i += 1) {
      const t = tokens[i];
      if (t === '--ignore-path' || t === '--config' || t === '-c') {
        i += 1;
        continue;
      }
      if (t.startsWith('-')) continue;
      scopes.push(cleanScope(t));
    }
    return { found: true, tokens, scopes: scopes.length > 0 ? scopes : ['.'] };
  }
  return { found: false, tokens: [], scopes: [] };
}

function inScopes(file, scopes) {
  return scopes.some((s) => s === '.' || file === s || file.startsWith(`${s}/`));
}

const specialWholeLint =
  pkg.name === '@n8n/eslint-plugin-community-nodes' ||
  pkg.name === '@n8n/oxlint-config' ||
  lint.includes('lint:docs') ||
  lint.includes('node -e');

const oxlint = extractToolScopes(lint, 'oxlint', null);
const eslint = extractToolScopes(lint, 'eslint', null);
const biome = runFormat ? extractToolScopes(fmt, 'biome', 'ci') : { found: false, scopes: [] };
const prettier = runFormat ? extractToolScopes(fmt, 'prettier', null) : { found: false, scopes: [] };

const oxlintFiles = !specialWholeLint && oxlint.found
  ? files.filter((f) => CODE_RE.test(f) && inScopes(f, oxlint.scopes))
  : [];
const eslintFiles = !specialWholeLint && eslint.found
  ? files.filter((f) => CODE_RE.test(f) && inScopes(f, eslint.scopes))
  : [];
const nodesBaseValidate =
  !specialWholeLint &&
  lint.includes('validate-schema-versions.js') &&
  files.some((f) => f.startsWith('nodes/') || f.startsWith('credentials/'));
const styleFiles = runStyles && styles.includes('stylelint')
  ? files.filter((f) => f.startsWith('src/') && STYLE_RE.test(f))
  : [];
const biomeFiles = biome.found ? files.filter((f) => inScopes(f, biome.scopes)) : [];
const prettierFiles = prettier.found ? files.filter((f) => inScopes(f, prettier.scopes)) : [];

const result = {
  specialWholeLint,
  genMigration: lint.includes('gen:migration-index'),
  oxlintTypeAware: oxlint.tokens.includes('--type-aware'),
  eslintQuiet: eslint.tokens.includes('--quiet'),
  nodesBaseHeap: lint.includes('--max-old-space-size=6144'),
  nodesBaseValidate,
  oxlintFiles,
  eslintFiles,
  styleFiles,
  biomeFiles,
  prettierFiles,
};
process.stdout.write(JSON.stringify(result));
NODE
)"

eval "$(node -e '
const p = JSON.parse(process.argv[1]);
const arr = (name, items) => `${name}=(${items.map((x) => JSON.stringify(x)).join(" ")})`;
console.log(`special_whole_lint=${p.specialWholeLint ? 1 : 0}`);
console.log(`gen_migration=${p.genMigration ? 1 : 0}`);
console.log(`oxlint_type_aware=${p.oxlintTypeAware ? 1 : 0}`);
console.log(`eslint_quiet=${p.eslintQuiet ? 1 : 0}`);
console.log(`nodes_base_heap=${p.nodesBaseHeap ? 1 : 0}`);
console.log(`nodes_base_validate=${p.nodesBaseValidate ? 1 : 0}`);
console.log(arr("oxlint_files", p.oxlintFiles));
console.log(arr("eslint_files", p.eslintFiles));
console.log(arr("style_files", p.styleFiles));
console.log(arr("biome_files", p.biomeFiles));
console.log(arr("prettier_files", p.prettierFiles));
' "$plan_output")"

need_code_deps=0
if [ "$special_whole_lint" -eq 1 ] || [ "${#oxlint_files[@]}" -gt 0 ] || [ "${#eslint_files[@]}" -gt 0 ] || [ "$nodes_base_validate" -eq 1 ]; then
  need_code_deps=1
fi

if [ "$need_code_deps" -eq 1 ]; then
  build_lint_deps
elif [ "${#style_files[@]}" -gt 0 ]; then
  "$SCRIPT_DIR/build-workspace-deps.sh" @n8n/stylelint-config
fi

cd "$ABS_PKG_DIR"

if [ "$special_whole_lint" -eq 1 ]; then
  pnpm run lint
else
  if [ "$gen_migration" -eq 1 ] && [ "${#oxlint_files[@]}" -gt 0 ] && [ -f scripts/generate-migration-index.mjs ]; then
    node scripts/generate-migration-index.mjs
  fi
  if [ "${#oxlint_files[@]}" -gt 0 ]; then
    oxlint_bin="$(local_bin oxlint)"
    oxlint_args=(--quiet --no-error-on-unmatched-pattern)
    [ "$oxlint_type_aware" -eq 1 ] && oxlint_args+=(--type-aware)
    "$oxlint_bin" "${oxlint_args[@]}" "${oxlint_files[@]}"
  fi
  if [ "${#eslint_files[@]}" -gt 0 ]; then
    eslint_bin="$(local_bin eslint)"
    eslint_args=(--no-warn-ignored --no-error-on-unmatched-pattern)
    [ "$eslint_quiet" -eq 1 ] && eslint_args+=(--quiet)
    if [ "$nodes_base_heap" -eq 1 ]; then
      NODE_OPTIONS="${NODE_OPTIONS:-} --max-old-space-size=6144" "$eslint_bin" "${eslint_args[@]}" "${eslint_files[@]}"
    else
      "$eslint_bin" "${eslint_args[@]}" "${eslint_files[@]}"
    fi
  fi
  if [ "$nodes_base_validate" -eq 1 ]; then
    node ./scripts/validate-load-options-methods.js
    node ./scripts/validate-schema-versions.js
  fi
fi

if [ "${#style_files[@]}" -gt 0 ]; then
  stylelint_bin="$(local_bin stylelint)"
  mkdir -p "$REPO_ROOT/.turbo"
  "$stylelint_bin" --cache --cache-location "$REPO_ROOT/.turbo/stylelintcache-$PKG_SLUG" --allow-empty-input "${style_files[@]}"
fi

if [ "${#biome_files[@]}" -gt 0 ]; then
  biome_bin="$(local_bin biome)"
  "$biome_bin" ci --no-errors-on-unmatched --files-ignore-unknown=true "${biome_files[@]}"
fi

if [ "${#prettier_files[@]}" -gt 0 ]; then
  prettier_bin="$(local_bin prettier)"
  "$prettier_bin" --check --ignore-unknown --no-error-on-unmatched-pattern --ignore-path "$REPO_ROOT/.prettierignore" "${prettier_files[@]}"
fi

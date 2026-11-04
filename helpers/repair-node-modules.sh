#!/usr/bin/env bash
set -euo pipefail

# repair-node-modules.sh: the repairs n8n's installed tree needs before its vitest runs,
# after the prepare phase's frozen install (`toolchain.node`: `enact run`'s prepare, CI's
# install step). Each is idempotent and guarded by a sentinel under node_modules, so a run
# after the first costs a few stats. It installs nothing: no node_modules, nothing to do.
# Run from a package directory (vitest-runner.sh) or the repository root.

[ -n "${REPO_ROOT:-}" ] || {
  REPO_ROOT="$PWD"
  while [ "$REPO_ROOT" != "/" ] && [ ! -f "$REPO_ROOT/pnpm-workspace.yaml" ] && [ ! -f "$REPO_ROOT/pnpm-lock.yaml" ]; do
    REPO_ROOT="$(dirname "$REPO_ROOT")"
  done
}
[ -d "$REPO_ROOT/node_modules" ] || exit 0

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

[ -d "$REPO_ROOT/packages/@n8n" ] || exit 0

# The workspace packages: linked where configs and tools resolve them
VITEST_HEALED_SENTINEL="$REPO_ROOT/node_modules/.enact-vitest-healed-v1"
if [ ! -f "$VITEST_HEALED_SENTINEL" ] || \
   [ ! -e "$REPO_ROOT/node_modules/vitest" ] || \
   [ ! -e "$PWD/node_modules/vitest" ] || \
   { [ ! -f "$REPO_ROOT/packages/frontend/editor-ui/index.js" ] && [ ! -e "$REPO_ROOT/node_modules/n8n-editor-ui/index.js" ]; } || \
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
  if [ ! -f "$REPO_ROOT/packages/frontend/editor-ui/index.js" ] && [ ! -f "$REPO_ROOT/node_modules/n8n-editor-ui/index.js" ]; then
    mkdir -p "$REPO_ROOT/node_modules/n8n-editor-ui"
    printf '{"name":"n8n-editor-ui","main":"index.js"}\n' > "$REPO_ROOT/node_modules/n8n-editor-ui/package.json" 2>/dev/null || true
    : > "$REPO_ROOT/node_modules/n8n-editor-ui/index.js" 2>/dev/null || true
    if [ -d "$REPO_ROOT/packages/cli/node_modules" ]; then
      ln -sfn "$REPO_ROOT/node_modules/n8n-editor-ui" "$REPO_ROOT/packages/cli/node_modules/n8n-editor-ui" 2>/dev/null || true
    fi
  fi

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

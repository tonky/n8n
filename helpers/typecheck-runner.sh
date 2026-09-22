#!/usr/bin/env bash
set -euo pipefail

# typecheck-runner.sh: Component-scoped TypeScript verification
CURRENT_PKG=$(node -p "try { require('./package.json').name } catch(e) { '' }" 2>/dev/null || true)

if [ -f "scripts/generate-migration-index.mjs" ]; then
  node scripts/generate-migration-index.mjs 2>/dev/null || true
fi

# Locate local repository TypeScript compiler
TSC_BIN=""
if [ -x "./node_modules/.bin/tsc" ]; then
  TSC_BIN="./node_modules/.bin/tsc"
elif [ -x "../../node_modules/.bin/tsc" ]; then
  TSC_BIN="../../node_modules/.bin/tsc"
elif [ -x "../../../node_modules/.bin/tsc" ]; then
  TSC_BIN="../../../node_modules/.bin/tsc"
elif command -v tsc >/dev/null 2>&1; then
  TSC_BIN="tsc"
else
  TSC_BIN="pnpm exec tsc"
fi

# Pre-build referenced project configs so declaration files exist in dist/
if [ -f "tsconfig.json" ]; then
  REFS=$(node -e '
    const fs = require("fs");
    try {
      const raw = fs.readFileSync("tsconfig.json", "utf8");
      const clean = raw.replace(/^\s*\/\/.*$/gm, "").replace(/,(\s*[}\]])/g, "$1");
      const json = JSON.parse(clean);
      const valid = (json.references || []).map(r => r.path).filter(p => fs.existsSync(p));
      console.log(valid.join(" "));
    } catch (e) {
      process.exit(0);
    }
  ' 2>/dev/null || true)

  if [ -n "$REFS" ]; then
    echo "📦 [typecheck-runner] Building local project references for '$CURRENT_PKG'..."
    $TSC_BIN -b $REFS 2>/dev/null || true
  fi
fi

echo "🔍 [typecheck-runner] Running scoped TypeScript typecheck for '$CURRENT_PKG'..."
export NODE_OPTIONS="${NODE_OPTIONS:---max-old-space-size=6144}"

exec $TSC_BIN -p tsconfig.json --noEmit

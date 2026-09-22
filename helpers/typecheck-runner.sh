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

# Pre-build local workspace dependencies checked out in the sparse cone
if [ -f "package.json" ]; then
  node -e '
    const fs = require("fs");
    const cp = require("child_process");
    try {
      const pkg = JSON.parse(fs.readFileSync("package.json", "utf8"));
      const deps = Object.entries(pkg.dependencies || {})
        .filter(([_, v]) => typeof v === "string" && v.startsWith("workspace:"))
        .map(([k]) => k);
      for (const dep of deps) {
        try {
          const realPath = fs.realpathSync(`node_modules/${dep}`);
          if (fs.existsSync(`${realPath}/src`) && fs.existsSync(`${realPath}/package.json`)) {
            const depPkg = JSON.parse(fs.readFileSync(`${realPath}/package.json`, "utf8"));
            const buildScript = depPkg.scripts?.["build:server"] ? "build:server" : depPkg.scripts?.["build:unchecked"] ? "build:unchecked" : depPkg.scripts?.["build"] ? "build" : null;
            if (buildScript) {
              cp.execSync(`pnpm --filter=${dep} run ${buildScript}`, { stdio: "ignore" });
            }
          }
        } catch (_) {}
      }
    } catch (_) {}
  ' 2>/dev/null || true
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

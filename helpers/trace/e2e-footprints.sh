#!/usr/bin/env bash
# ==============================================================================
# e2e-footprints.sh <spec...> - Runs Playwright e2e specs, recording their footprints
# ==============================================================================
# playwright-runner.sh hands its specs here (relative to the playwright package, as the
# job passes them) when enact wants footprints (ENACT_FOOTPRINT_DIR: `enact reach record`,
# every spec; `enact run` recording, the specs ENACT_FOOTPRINT_TARGETS lists).
#
# Instead of spawning `run-local-isolated.mjs` + `pnpm` twice per spec and migrating ~100
# SQLite tables 200+ times sequentially:
#   1. Pre-migrates a clean `.n8n/{database.sqlite,config}` template once per shard using
#      `N8N_ENCRYPTION_KEY="e2e-test-encryption-key-n8n"` and `n8n-ready.mjs --readiness`.
#   2. Copies the pre-migrated `.n8n/` template per spec (`cp -R`, <5ms), boots
#      `node packages/cli/bin/n8n start` directly on distinct ports under `node-reads.mjs`,
#      and runs Playwright (`--project=e2e --workers 1 --trace=off`, `RESET_E2E_DB=false` so
#      `dbSetup` resets with valid credentials without `setupUserManagement` null-password
#      errors).
#   3. Runs non-proxy specs 2-wide concurrently while `flock`-serializing `proxy`-using specs
#      (concurrency 1) so shared `:1088` MockServer expectations never race across specs.
#
# Env: ENACT_FOOTPRINT_DIR · ENACT_FOOTPRINT_TARGETS · ENACT_SHARD_INDEX
set -uo pipefail

TRACE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TRACE_DIR/../.." && pwd)"
HELPERS_DIR="$TRACE_DIR/.."
RECORDERS_JS="${ENACT_RECORDERS_DIR:+$ENACT_RECORDERS_DIR/js}"
if [ -z "$RECORDERS_JS" ] || [ ! -d "$RECORDERS_JS" ]; then
  if [ -d "$TRACE_DIR/../../../../../crates/enact-runner/recorders/js" ]; then
    RECORDERS_JS="$(cd "$TRACE_DIR/../../../../../crates/enact-runner/recorders/js" && pwd)"
  elif [ -d "$REPO_ROOT/../../crates/enact-runner/recorders/js" ]; then
    RECORDERS_JS="$(cd "$REPO_ROOT/../../crates/enact-runner/recorders/js" && pwd)"
  else
    RECORDERS_JS="$TRACE_DIR"
  fi
fi
PLAYWRIGHT_DIR="$REPO_ROOT/packages/quality/testing/playwright"
PACKAGE="${PLAYWRIGHT_DIR#"$REPO_ROOT"/}"
LISTED=${ENACT_FOOTPRINT_TARGETS:-}
export N8N_ENCRYPTION_KEY="${N8N_ENCRYPTION_KEY:-e2e-test-encryption-key-n8n}"
unset CURRENTS_RECORD_KEY

PW_EXTRA_ARGS=()
if [ -f "$PLAYWRIGHT_DIR/playwright.config.ts" ] && [ -f "$HELPERS_DIR/playwright.enact.config.ts" ]; then
  PW_EXTRA_ARGS=(--config "$HELPERS_DIR/playwright.enact.config.ts" --trace=off)
else
  PW_EXTRA_ARGS=(--trace=off)
fi

wanted() { # <repository-relative spec>
  [ -n "$LISTED" ] || return 0
  awk -v t="$1" '$0 == t || index($0, t "::") == 1 { found = 1; exit } END { exit !found }' "$LISTED"
}

isolated_fallback() {
  local workers=$1
  shift
  [ "$workers" != - ] || workers=${N8N_PW_WORKERS:-}
  node --import "$HELPERS_DIR/n8n-ready.mjs" "$PLAYWRIGHT_DIR/scripts/run-local-isolated.mjs" \
    ${workers:+--workers "$workers"} "${PW_EXTRA_ARGS[@]}" "$@"
}

RECORDED=()
UNRECORDED=()
for spec in "$@"; do
  if wanted "$PACKAGE/${spec#./}"; then RECORDED+=("${spec#./}"); else UNRECORDED+=("$spec"); fi
done

spec_group() { # <spec>: `<env>\t<workers>`
  local groups
  groups=$(node "$HELPERS_DIR/pw-spec-env.mjs" "$PLAYWRIGHT_DIR" "$1") || return "$?"
  [ -n "$groups" ] || { echo "e2e-footprints: no group for requested spec $1" >&2; return 1; }
  printf '%s\n' "$groups" | cut -f1,2
}

# Resolve capability/env upfront for every requested spec before chunk indexing or server boot,
# so invalid capability metadata fails fast with the resolver's exact exit code.
UNRECORDED_GROUPS=""
if [ ${#UNRECORDED[@]} -gt 0 ]; then
  UNRECORDED_GROUPS=$(node "$HELPERS_DIR/pw-spec-env.mjs" "$PLAYWRIGHT_DIR" "${UNRECORDED[@]}") || exit "$?"
  [ -n "$UNRECORDED_GROUPS" ] || { echo "e2e-footprints: no groups for requested specs" >&2; exit 1; }
fi

SPEC_ENVS=()
for spec in "${RECORDED[@]}"; do
  group=$(spec_group "$spec") || exit "$?"
  IFS=$'\t' read -r spec_env _spec_workers <<< "$group"
  SPEC_ENVS+=("$spec_env")
done

status=0
if [ -n "$UNRECORDED_GROUPS" ]; then
  while IFS=$'\t' read -r -a group; do
    N8N_TEST_ENV="${group[0]}" isolated_fallback "${group[1]}" "${group[@]:2}" || status=$?
  done <<< "$UNRECORDED_GROUPS"
fi
[ ${#RECORDED[@]} -gt 0 ] || exit "$status"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/enact-e2e-footprints.XXXXXX")
mkdir -p "$WORK/pids" "$WORK/skips" "$WORK/status" "$WORK/logs"

stop_pid_gracefully() {
  local pid=$1
  [ -n "$pid" ] || return 0
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    local waited=0
    while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 50 ]; do
      sleep 0.1
      waited=$((waited + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  fi
  wait "$pid" 2>/dev/null || true
}

cleanup_all() {
  local pidfile pid
  if [ -d "$WORK/pids" ]; then
    for pidfile in "$WORK"/pids/*.pid; do
      [ -f "$pidfile" ] || continue
      pid=$(cat "$pidfile" 2>/dev/null || true)
      stop_pid_gracefully "$pid"
      rm -f "$pidfile"
    done
  fi
  rm -rf "$WORK"
}
trap cleanup_all EXIT
trap 'cleanup_all; exit 130' INT
trap 'cleanup_all; exit 143' TERM

# Reuse the editor UI Vite chunk map produced by playwright:build inside dist/, lazily
# building it on local runs when missing.
DIST_CHUNKS="$REPO_ROOT/packages/frontend/editor-ui/dist/.enact-editor-chunks.json"
CHUNKS="$DIST_CHUNKS"
chunks_ok=0
if [ -f "$HELPERS_DIR/editor-chunks.mjs" ] && [ -f "$REPO_ROOT/packages/frontend/editor-ui/dist/index.html" ]; then
  if ENACT_FOOTPRINT_ROOT="$REPO_ROOT" node "$HELPERS_DIR/editor-chunks.mjs" "$DIST_CHUNKS"; then
    chunks_ok=1
  fi
else
  CHUNKS="$WORK/chunks.json"
  if ENACT_FOOTPRINT_ROOT="$REPO_ROOT" node "$RECORDERS_JS/vite-chunks.mjs" --root packages/frontend/editor-ui --public-path '/{{BASE_PATH}}/' "$CHUNKS"; then
    chunks_ok=1
  fi
fi

if [ "$chunks_ok" -ne 1 ]; then
  echo "❌ [e2e-footprints] the editor's build couldn't be mapped to its sources: the specs run unrecorded" >&2
  groups=$(node "$HELPERS_DIR/pw-spec-env.mjs" "$PLAYWRIGHT_DIR" "${RECORDED[@]}") || exit "$?"
  [ -n "$groups" ] || { echo "e2e-footprints: no groups for requested specs" >&2; exit 1; }
  while IFS=$'\t' read -r -a group; do
    N8N_TEST_ENV="${group[0]}" isolated_fallback "${group[1]}" "${group[@]:2}" || status=$?
  done <<< "$groups"
  exit "$status"
fi

# Classify proxy-using specs (`services: ['proxy']`) so they flock-serialize on :1088
# while non-proxy specs run 2-wide concurrently on distinct ports.
SPEC_PROXY_FLAGS=()
while IFS= read -r flag; do
  SPEC_PROXY_FLAGS+=("$flag")
done < <(
  node --input-type=module - "$HELPERS_DIR/pw-capability.mjs" "$PLAYWRIGHT_DIR" "${RECORDED[@]}" <<'EOF'
import { pathToFileURL } from 'node:url';
const [capModule, pwDir, ...specs] = process.argv.slice(2);
const { capabilityReader } = await import(pathToFileURL(capModule).href);
const readCap = capabilityReader(pwDir);
for (const spec of specs) {
  let usesProxy = false;
  try {
    const cap = readCap(spec);
    usesProxy = Array.isArray(cap?.services) && cap.services.includes('proxy');
  } catch {
    usesProxy = false;
  }
  console.log(usesProxy ? '1' : '0');
}
EOF
)

alloc_two_ports() {
  (
    flock -x 9
    node -e '
      const net = require("node:net");
      const used = new Set(
        require("node:fs").existsSync(process.argv[1])
          ? require("node:fs").readFileSync(process.argv[1], "utf8").split(/\s+/).filter(Boolean).map(Number)
          : []
      );
      async function pick() {
        for (;;) {
          const p = await new Promise((res, rej) => {
            const s = net.createServer();
            s.unref();
            s.on("error", rej);
            s.listen(0, "127.0.0.1", () => {
              const port = s.address().port;
              s.close(() => res(port));
            });
          });
          if (!used.has(p)) {
            used.add(p);
            return p;
          }
        }
      }
      (async () => {
        const a = await pick();
        const b = await pick();
        require("node:fs").appendFileSync(process.argv[1], `${a}\n${b}\n`);
        process.stdout.write(`${a} ${b}\n`);
      })();
    ' "$WORK/allocated.ports"
  ) 9>"$WORK/ports.lock"
}

json_env_assignments() {
  node -e '
    const obj = JSON.parse(process.argv[1] || "{}");
    for (const [k, v] of Object.entries(obj)) {
      if (/^[A-Za-z_][A-Za-z0-9_]*$/.test(k) && typeof v === "string") {
        process.stdout.write(`${k}=${JSON.stringify(v)}\0`);
      }
    }
  ' "$1"
}

N8N_CLI_BIN="$REPO_ROOT/packages/cli/bin/n8n"
if [ -x "$PLAYWRIGHT_DIR/node_modules/.bin/playwright" ]; then
  PW_CMD=("$PLAYWRIGHT_DIR/node_modules/.bin/playwright")
else
  PW_CMD=(pnpm --dir "$PLAYWRIGHT_DIR" exec playwright)
fi

# Pre-migrate a clean template `.n8n/{database.sqlite,config}` once per shard.
TEMPLATE_DIR="$WORK/template-user"
mkdir -p "$TEMPLATE_DIR"
read -r tpl_port tpl_broker <<< "$(alloc_two_ports)"
(
  cd "$REPO_ROOT" &&
    exec env \
      E2E_TESTS=true \
      DB_TYPE=sqlite \
      N8N_PORT="$tpl_port" \
      N8N_RUNNERS_BROKER_PORT="$tpl_broker" \
      N8N_USER_FOLDER="$TEMPLATE_DIR" \
      N8N_ENCRYPTION_KEY="$N8N_ENCRYPTION_KEY" \
      N8N_DIAGNOSTICS_ENABLED=false \
      N8N_VERSION_NOTIFICATIONS_ENABLED=false \
      N8N_METRICS=false \
      N8N_LOG_LEVEL="${N8N_LOG_LEVEL:-warn}" \
      N8N_RESTRICT_FILE_ACCESS_TO="" \
      node "$N8N_CLI_BIN" start
) >"$WORK/logs/template.log" 2>&1 &
tpl_pid=$!
printf '%s\n' "$tpl_pid" > "$WORK/pids/template.pid"

if ! node "$HELPERS_DIR/n8n-ready.mjs" --readiness "http://127.0.0.1:$tpl_port" "$tpl_pid"; then
  echo "❌ [e2e-footprints] failed to initialize pre-migrated SQLite template:" >&2
  cat "$WORK/logs/template.log" >&2 || true
  stop_pid_gracefully "$tpl_pid"
  rm -f "$WORK/pids/template.pid"
  exit 1
fi
stop_pid_gracefully "$tpl_pid"
rm -f "$WORK/pids/template.pid"

if [ ! -d "$TEMPLATE_DIR/.n8n" ]; then
  echo "❌ [e2e-footprints] pre-migrated template missing $TEMPLATE_DIR/.n8n" >&2
  exit 1
fi

run_one_spec() {
  local idx=$1
  local arr_idx=$((idx - 1))
  local spec="${RECORDED[$arr_idx]}"
  local spec_env="${SPEC_ENVS[$arr_idx]}"
  local is_proxy="${SPEC_PROXY_FLAGS[$arr_idx]:-0}"
  if [[ "$spec_env" == *'"HTTP_PROXY"'* ]]; then
    is_proxy=1
  fi

  local user_dir="$WORK/user/$idx"
  mkdir -p "$user_dir"
  cp -R "$TEMPLATE_DIR/.n8n" "$user_dir/.n8n"

  local port broker_port
  read -r port broker_port <<< "$(alloc_two_ports)"
  local base_url="http://127.0.0.1:$port"

  local extra_env=()
  while IFS= read -r -d '' kv; do
    # Strip JSON quotes around value emitted by json_env_assignments
    local key="${kv%%=*}"
    local raw_val="${kv#*=}"
    local val
    val=$(node -p 'JSON.parse(process.argv[1])' "$raw_val")
    extra_env+=("$key=$val")
  done < <(json_env_assignments "$spec_env")

  local preload="--import $RECORDERS_JS/node-reads.mjs"
  local traced_node_opts="$preload${NODE_OPTIONS:+ $NODE_OPTIONS}"

  echo "🎙️  [e2e-footprints] $idx/${#RECORDED[@]}: $spec (port $port, proxy=$is_proxy)"
  (
    cd "$REPO_ROOT" &&
      exec env \
        E2E_TESTS=true \
        DB_TYPE=sqlite \
        N8N_PORT="$port" \
        N8N_RUNNERS_BROKER_PORT="$broker_port" \
        N8N_USER_FOLDER="$user_dir" \
        N8N_ENCRYPTION_KEY="$N8N_ENCRYPTION_KEY" \
        N8N_DIAGNOSTICS_ENABLED=false \
        N8N_VERSION_NOTIFICATIONS_ENABLED=false \
        N8N_LOG_LEVEL="${N8N_LOG_LEVEL:-warn}" \
        N8N_RESTRICT_FILE_ACCESS_TO="" \
        N8N_TEST_ENV="$spec_env" \
        ENACT_NODE_READS="$WORK/node/$idx" \
        ENACT_FOOTPRINT_ROOT="$REPO_ROOT" \
        NODE_OPTIONS="$traced_node_opts" \
        ${extra_env[@]+"${extra_env[@]}"} \
        node "$N8N_CLI_BIN" start
  ) >"$WORK/logs/server-$idx.log" 2>&1 &
  local srv_pid=$!
  printf '%s\n' "$srv_pid" > "$WORK/pids/$idx.pid"

  local spec_status=0
  if ! node "$HELPERS_DIR/n8n-ready.mjs" --readiness "$base_url" "$srv_pid"; then
    echo "❌ [e2e-footprints] n8n failed readiness for $spec:" >&2
    tail -n 50 "$WORK/logs/server-$idx.log" >&2 || true
    spec_status=1
  else
    (
      cd "$PLAYWRIGHT_DIR" &&
        env \
          N8N_BASE_URL="$base_url" \
          N8N_TEST_ENV="$spec_env" \
          ENACT_PW_BACKEND=shared \
          PLAYWRIGHT_ALLOW_CONTAINER_ONLY=true \
          PLAYWRIGHT_SKIP_WEBSERVER=true \
          RESET_E2E_DB=false \
          ENACT_NODE_READS="$WORK/node/$idx" \
          ENACT_FOOTPRINT_ROOT="$REPO_ROOT" \
          NODE_OPTIONS="$traced_node_opts" \
          ENACT_SKIPS_FILE="$WORK/skips/$idx.jsonl" \
          "${PW_CMD[@]}" test --project=e2e --workers 1 \
          "${PW_EXTRA_ARGS[@]}" \
          --output="$WORK/results/$idx" \
          "--reporter=list,$RECORDERS_JS/playwright-attribution.mjs" \
          "$spec"
    ) || spec_status=$?
    if [ "$spec_status" -ne 0 ]; then
      echo "⚠️  [e2e-footprints] $spec exited $spec_status; last server log lines:" >&2
      tail -n 30 "$WORK/logs/server-$idx.log" >&2 || true
    fi
  fi

  stop_pid_gracefully "$srv_pid"
  rm -f "$WORK/pids/$idx.pid"
  rm -rf "$user_dir"
  printf '%s\n' "$spec_status" > "$WORK/status/$idx"
  return "$spec_status"
}

run_one_spec_maybe_locked() {
  local idx=$1
  local arr_idx=$((idx - 1))
  local is_proxy="${SPEC_PROXY_FLAGS[$arr_idx]:-0}"
  if [[ "${SPEC_ENVS[$arr_idx]}" == *'"HTTP_PROXY"'* ]]; then
    is_proxy=1
  fi
  if [ "$is_proxy" = "1" ]; then
    (
      flock -x 8
      run_one_spec "$idx"
    ) 8>"$WORK/proxy.lock"
  else
    run_one_spec "$idx"
  fi
}

printf '0\n' > "$WORK/next_idx"
TOTAL=${#RECORDED[@]}
CONCURRENCY="${E2E_FOOTPRINT_CONCURRENCY:-2}"
[ "$TOTAL" -lt "$CONCURRENCY" ] && CONCURRENCY="$TOTAL"

next_spec_index() {
  (
    flock -x 7
    local cur
    cur=$(cat "$WORK/next_idx")
    cur=$((cur + 1))
    if [ "$cur" -le "$TOTAL" ]; then
      printf '%s\n' "$cur" > "$WORK/next_idx"
      printf '%s\n' "$cur"
    fi
  ) 7>"$WORK/queue.lock"
}

worker_loop() {
  local idx
  while :; do
    idx=$(next_spec_index)
    [ -n "$idx" ] || break
    run_one_spec_maybe_locked "$idx" || true
  done
}

WORKER_PIDS=()
for ((w = 0; w < CONCURRENCY; w++)); do
  worker_loop &
  WORKER_PIDS+=("$!")
done
for wpid in "${WORKER_PIDS[@]}"; do
  wait "$wpid" || true
done

RESULTS=()
for ((i = 1; i <= TOTAL; i++)); do
  spec_rc=1
  [ -f "$WORK/status/$i" ] && spec_rc=$(cat "$WORK/status/$i")
  [ "$spec_rc" -eq 0 ] || status="$spec_rc"
  RESULTS+=("$PACKAGE/${RECORDED[$((i - 1))]}=$spec_rc")
done

ENACT_FOOTPRINT_ROOT="$REPO_ROOT" node "$RECORDERS_JS/e2e-footprint.mjs" write "$WORK" "$CHUNKS" "${RESULTS[@]}" || status=1
exit "$status"

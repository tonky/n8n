#!/usr/bin/env bash
# ==============================================================================
# trace-test.sh <map> <test> - Traces one test file into <map> (an enact reach map, JSON)
# ==============================================================================
# The per-file way a test file is traced: generate-reach-map.sh calls it for every test it
# traces, while footprints.sh uses trace-files.sh to trace a shard's tests in one batch with
# `--attribution` during `enact run` and `enact trace record`.
#
# `enact trace run` records the files the process tree opens while the test runs as its
# test job runs it: from its package's directory, through vitest-runner.sh in the
# repository's environment (unit tests on SQLite, integration tests on PostgreSQL). The
# task's declared services are conservatively recorded as its own (`--service-dep`), so a
# change to them reaches it. Exits as the test did; a failing test is incomplete.
#
# Env: ENACT_EXE (the enact running the task, which sets it), else ENACT_BIN (default: enact on
#      PATH)
set -euo pipefail

MAP=$1
TEST=$2
ROOT=$(git rev-parse --show-toplevel)
ENACT=${ENACT_EXE:-${ENACT_BIN:-$(command -v enact || true)}}
[ -n "$ENACT" ] || { echo "trace-test.sh: no enact on PATH: put it there or set ENACT_BIN" >&2; exit 2; }

# The package the test belongs to: the nearest directory with a package.json.
DIR=$(dirname "$TEST")
while [ "$DIR" != . ] && [ ! -f "$ROOT/$DIR/package.json" ]; do
  DIR=$(dirname "$DIR")
done

FLAGS=()
services=${ENACT_FOOTPRINT_SERVICES-${SERVICE_DEPS:-}}
if [ "${ENACT_SERVICES_ACTIVE:-0}" = 1 ] && [ -z "$services" ]; then
  echo "trace-test.sh: active services need declared recording services" >&2
  exit 1
fi
for service in $services; do FLAGS+=(--service-dep "$service"); done

ENVE_FLAGS=()
case "${ENACT_NO_ISOLATE:-}" in
  1 | true) ENVE_FLAGS+=(--isolation host) ;;
esac

cd "$ROOT/$DIR"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/enact-trace-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
status=0
"$ENACT" trace run --no-fingerprint --node-functions --reach-file "$WORK/map.json" -t "$TEST" ${FLAGS[@]+"${FLAGS[@]}"} -- \
  enve run --locked -q ${ENVE_FLAGS[@]+"${ENVE_FLAGS[@]}"} -f "$ROOT/enve.cue" -- "$ROOT/helpers/vitest-runner.sh" "${TEST#"$DIR"/}" || status=$?
if [ ! -s "$WORK/map.json" ]; then
  [ "$status" -ne 0 ] || status=1
  exit "$status"
fi
# Only the fresh output of this invocation can acquire the adapter capability; never
# stamp a pre-existing destination or another target the native recorder returned.
node - "$WORK/map.json" "$MAP" "$TEST" "$services" <<'JS'
const fs = require('node:fs');
const [from, to, target, services] = process.argv.slice(2);
const map = JSON.parse(fs.readFileSync(from, 'utf8'));
const fp = map.targets?.[target];
if (!fp) throw new Error(`trace-test.sh: the fresh trace has no target ${target}`);
if (services) fp.recorders = [...new Set([...(fp.recorders || []), 'n8n-services/1'])];
fs.writeFileSync(to + '.part', JSON.stringify(map));
fs.renameSync(to + '.part', to);
JS
exit "$status"

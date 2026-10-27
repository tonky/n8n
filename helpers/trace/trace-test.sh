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
# services an integration test uses are recorded as its own (`--service-dep`), so a change
# to them reaches it. Exits as the test did; a test that fails is recorded incomplete.
#
# Env: ENACT_EXE (the enact running the task, which sets it), else ENACT_BIN (default: enact on
#      PATH)
set -euo pipefail

MAP=$1
TEST=$2
ROOT=$(git rev-parse --show-toplevel)
ENACT=${ENACT_EXE:-${ENACT_BIN:-$(command -v enact || true)}}
[ -n "$ENACT" ] || { echo "trace-test.sh: no enact on PATH: put it there or set ENACT_BIN" >&2; exit 2; }

# The tests vitest-runner.sh sends to PostgreSQL, and those connecting to it.
INTEGRATION='^packages/cli/(test/(integration|migration)/.*|src/.*\.integration)\.test\.ts$|\.postgres\.test\.ts$'

# The package the test belongs to: the nearest directory with a package.json.
DIR=$(dirname "$TEST")
while [ "$DIR" != . ] && [ ! -f "$ROOT/$DIR/package.json" ]; do
  DIR=$(dirname "$DIR")
done

FLAGS=()
if [[ $TEST =~ $INTEGRATION ]]; then
  FLAGS=(--service-dep postgres --service-dep redis)
fi

cd "$ROOT/$DIR"
exec "$ENACT" trace run --no-fingerprint --node-functions --reach-file "$MAP" -t "$TEST" "${FLAGS[@]}" -- \
  enve run --locked -q -f "$ROOT/enve.cue" -- "$ROOT/helpers/vitest-runner.sh" "${TEST#"$DIR"/}"

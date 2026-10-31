#!/usr/bin/env bash
# ==============================================================================
# trace-files.sh <map> [<target>...] - Traces one run of the targets into <map>, a
# footprint per test file (an enact reach map, JSON)
# ==============================================================================
# The per-shard way to trace test files, as trace-test.sh is the per-file one:
# `enact trace run --attribution` traces vitest-runner.sh running the targets (relative to
# the package directory this runs from, as its test job passes them; none: the whole
# suite) in the repository's environment. Seeing ENACT_ATTRIBUTION_FILE, vitest-runner.sh
# runs vitest with a forked worker per test file and the attribution reporter
# (vitest-attribution.mjs): each test file's footprint is its worker's reads, the modules vitest
# loaded for it, and the reads the run shares. Exits as the run did; a failed test file, or one
# the reporter couldn't attribute whole, is recorded incomplete.
#
# Env: ENACT_EXE (the enact running the task, which sets it), else ENACT_BIN (default: enact on
#      PATH)
#      · SERVICE_DEPS (services every footprint uses, spaced)
set -euo pipefail

MAP=$1
shift
ROOT=$(git rev-parse --show-toplevel)
ENACT=${ENACT_EXE:-${ENACT_BIN:-$(command -v enact || true)}}
[ -n "$ENACT" ] || { echo "trace-files.sh: no enact on PATH: put it there or set ENACT_BIN" >&2; exit 2; }

FLAGS=()
ENVE_FLAGS=()
case "${ENACT_NO_ISOLATE:-}" in
  1 | true) ENVE_FLAGS+=(--isolation host) ;;
esac
for service in ${SERVICE_DEPS:-}; do
  FLAGS+=(--service-dep "$service")
done

exec "$ENACT" trace run --no-fingerprint --node-functions --reach-file "$MAP" --attribution "$MAP.attribution.jsonl" \
  ${FLAGS[@]+"${FLAGS[@]}"} -- \
  enve run --locked -q ${ENVE_FLAGS[@]+"${ENVE_FLAGS[@]}"} -f "$ROOT/enve.cue" -- "$ROOT/helpers/vitest-runner.sh" "$@"

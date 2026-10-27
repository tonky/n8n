#!/usr/bin/env bash
# ==============================================================================
# generate-reach-map.sh - Records the reach map into the reach store, one trace per test file
# ==============================================================================
# enact prunes a suite only when the map traced every one of its tests
# (`target_scope.tests`), so every suite is traced whole, each test file as its job runs
# it (vitest-runner.sh: unit tests on SQLite, integration tests on PostgreSQL):
#   unit         every package's vitest suite (.enact/packages.cue): `enact trace run`
#                records the files the vitest process tree opens (JOBS at a time)
#   integration  the tests that need the database (cli's integration tests, db's
#                `*.postgres.test.ts`), against the traced postgres and redis services
# The tests import the workspace packages they depend on from their builds (`dist/`):
# `analysis.derived` maps a change to a package's sources to the tests that read its build.
#
# Incremental: over the stored map at HEAD (or an ancestor), only the tests `enact trace stale`
# lists are traced (untraced, failed, or a file, directory or service they used changed
# since), and their traces replace theirs in it; a phase with none starts nothing.
#
# Usage: helpers/trace/generate-reach-map.sh [unit] [integration]   (default: both)
# Env:   JOBS (parallel unit tests, default nproc) · INTEGRATION_JOBS (default 2) · ENACT_EXE
#        (set in enact tasks), else ENACT_BIN (default: enact on PATH) · ONLY (regex: trace only the matching tests, for a quick
#        check) · SUITE (regex: only the packages whose directory matches) · FULL=1 (trace every test, from scratch: a map of only what this run
#        traced) · BUILD=0 (the packages are built)
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel)
cd "$ROOT"
ENACT=${ENACT_EXE:-${ENACT_BIN:-$(command -v enact || true)}}
[ -n "$ENACT" ] || { echo "generate-reach-map.sh: no enact on PATH: put it there or set ENACT_BIN" >&2; exit 2; }
JOBS=${JOBS:-$(nproc)}
WORK=$ROOT/.enact/state/cache/trace-work
# The map is recorded into the reach store (`enact trace store where`), over the stored
# map selected at HEAD unless FULL.
BASE=
[ -n "${FULL:-}" ] || BASE=$("$ENACT" trace store where --path)
read -r -a PHASES <<<"${*:-unit integration}"
ENACT_BIN=$ENACT
export ROOT ENACT ENACT_BIN WORK

# Suites: package directory · test globs, as `target_scope.tests` names them: every
# package's vitest suite in .enact/packages.cue (SUITE, a regex, narrows them to the matching
# directories). The integration phase's tests are the ones vitest-runner.sh sends to
# PostgreSQL, and those connecting to it.
mapfile -t SUITES < <(python3 - "${SUITE:-.}" <<'PY'
import json, re, sys

def expand(glob):  # git pathspecs have no braces
    m = re.search(r"\{([^{}]*)\}", glob)
    if not m:
        return [glob]
    return [g for alt in m.group(1).split(",") for g in expand(glob[:m.start()] + alt + glob[m.end():])]

for line in open(".enact/packages.cue"):
    m = re.match(r'^\t"[^"]+": (\{.*\})$', line)
    if m:
        p = json.loads(m.group(1))
        if p["tests"] and re.search(sys.argv[1], p["dir"]):
            print(" ".join([p["dir"]] + [g for t in p["tests"] for g in expand(t)]))
PY
)
# No suite: the listing failed (its exit status is lost in the substitution) or SUITE matches
# none. Never "nothing to trace".
if [ ${#SUITES[@]} -eq 0 ]; then
  echo "❌ no vitest suite in .enact/packages.cue${SUITE:+ matching $SUITE}" >&2
  exit 1
fi
INTEGRATION='^packages/cli/(test/(integration|migration)/.*|src/.*\.integration)\.test\.ts$|\.postgres\.test\.ts$'

# tests <phase> <glob...>: tracked test files of the phase; ONLY (a regex) narrows them.
tests() {
  local phase=$1 test
  shift
  git ls-files -- "${@/#/:(glob)}" | while read -r test; do
    if [ "$phase" = integration ]; then [[ $test =~ $INTEGRATION ]] || continue; else [[ ! $test =~ $INTEGRATION ]] || continue; fi
    [[ $test =~ ${ONLY:-.} ]] || continue
    echo "$test"
  done
}

lines() { if [ -n "$1" ]; then wc -l <<<"$1" | tr -d ' '; else echo 0; fi; }

# to_trace <phase> <glob...>: the tests to trace (every one, or the stale ones over BASE),
# counted on stderr. Run after the builds the tests read: their outputs are in the
# footprints. Fails when `enact trace stale` does (its reasons go to the log): an error
# must not read as nothing to trace.
to_trace() {
  local all stale
  all=$(tests "$@")
  stale=$all
  if [ -n "$BASE" ] && [ -n "$all" ]; then
    if ! stale=$(xargs "$ENACT" trace stale --reach-file "$BASE" <<<"$all" 2>>"$WORK/logs/stale.log"); then
      echo "❌ enact trace stale failed for $2: $WORK/logs/stale.log" >&2
      return 1
    fi
  fi
  echo "🔍 $2 ($1): $(lines "$stale") of $(lines "$all") tests to trace" >&2
  [ -z "$stale" ] || echo "$stale"
}

# trace_test <test>: one test file into its own map in the phase's MAPS (tests trace in
# parallel, fingerprinted with the phase), running it as its test job does
# (trace-test.sh: its package's directory, vitest-runner.sh, its services).
trace_test() {
  local test=$1
  local name=${test//\//__}
  if "$ROOT/helpers/trace/trace-test.sh" "$MAPS/$name.json" "$test" >"$WORK/logs/$name.log" 2>&1; then
    echo "  ✓ $test"
  else
    echo "  ⚠️  $test failed, its trace is kept: $WORK/logs/$name.log"
  fi
}
export -f trace_test

# trace_tests <jobs> <tests>: the tests (one per line), jobs at a time.
trace_tests() {
  [ -n "$2" ] || return 0
  xargs -P "$1" -I{} bash -c 'trace_test "$@"' _ {} <<<"$2"
}

# services_up <service...>: starts them in the background, traced as SERVICE_DEPS.
# Stopping enact stops them, and it records what they read once they exit.
services_up() {
  # shellcheck disable=SC2086 # a list of names
  "$ENACT" trace service ${SERVICE_DEPS:?} --reach-file "$MAPS/services.json" -- \
    enve up --locked -q "$@" >"$WORK/logs/services.log" 2>&1 &
  SERVICES=$!
  trap services_down EXIT
}

services_down() {
  [ -n "${SERVICES:-}" ] || return 0
  kill -INT "$SERVICES" 2>/dev/null || true
  wait "$SERVICES" 2>/dev/null || true
  SERVICES=
}

# await <what> <command...>: polls the command for up to 4 minutes.
await() {
  local what=$1
  shift
  for _ in $(seq 240); do
    "$@" >/dev/null 2>&1 && return 0
    sleep 1
  done
  echo "❌ $what not ready: $WORK/logs/" >&2
  exit 1
}

phase_unit() {
  local suite parts stale
  for suite in "${SUITES[@]}"; do
    read -r -a parts <<<"$suite"
    stale=$(to_trace unit "${parts[@]:1}") || exit 1
    trace_tests "$JOBS" "$stale"
  done
}

phase_integration() {
  local suite parts stale=()
  for suite in "${SUITES[@]}"; do
    read -r -a parts <<<"$suite"
    stale+=("$(to_trace integration "${parts[@]:1}")") || exit 1
  done
  [ -n "${stale[*]// /}" ] || return 0
  export SERVICE_DEPS="postgres redis"
  services_up postgres redis
  await postgres enve run --locked -q -- pg_isready -h 127.0.0.1 -p "${DB_POSTGRESDB_PORT:?the postgres port (enve.cue)}"
  # Each test file clones a database of its own (backend-test-utils' testDb) and opens a
  # pool on it: a few at a time stay within the service's 100 connections.
  local i=0
  for suite in "${SUITES[@]}"; do
    read -r -a parts <<<"$suite"
    trace_tests "${INTEGRATION_JOBS:-2}" "${stale[$i]}"
    i=$((i + 1))
  done
  services_down
  unset SERVICE_DEPS
}

# This run's traces only: they are laid over BASE.
rm -rf "$WORK/maps" "$WORK/logs"
mkdir -p "$WORK/maps" "$WORK/logs"

# The tests import the built workspace packages: build them once, not in every traced run.
if [ "${BUILD:-1}" != 0 ]; then
  echo "🔨 building the workspace packages the suites import"
  enve run --locked -q -- pnpm turbo run build --concurrency="$JOBS" --continue \
    >"$WORK/logs/build.log" 2>&1 || echo "⚠️  some builds failed: $WORK/logs/build.log"
fi
# The traced runs' vitest-runner.sh doesn't build (build-workspace-deps.sh): its turbo's reads
# would enter every footprint.
export N8N_WORKSPACE_DEPS_BUILT=1

for phase in "${PHASES[@]}"; do
  export MAPS=$WORK/maps/$phase
  mkdir -p "$MAPS"
  "phase_$phase"
  phase_maps=("$MAPS"/*.json)
  if [ -e "${phase_maps[0]}" ]; then
    "$ENACT" trace pack --fingerprint "${phase_maps[@]}" -o "$WORK/maps/$phase.json" >/dev/null
  fi
done

maps=("$WORK"/maps/*.json)
if [ ! -e "${maps[0]}" ]; then
  echo "✅ every test's trace is current: the stored map is unchanged"
  exit 0
fi
"$ENACT" trace pack ${BASE:+--base "$BASE"} "${maps[@]}" -o "$WORK/reach.bin"
"$ENACT" trace store put "$WORK/reach.bin"

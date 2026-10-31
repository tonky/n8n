#!/usr/bin/env bash
# ==============================================================================
# footprints.sh <runner> <target...> - Runs a test job's targets, recording footprints
# ==============================================================================
# Recording while running: enact sets ENACT_FOOTPRINT_DIR in a shard's
# task when it wants footprints from it (`enact run`: the tests its map lacks, holds aged
# or failing, or the change reaches, listed in ENACT_FOOTPRINT_TARGETS; `enact trace
# record`: every test, no list). vitest-runner.sh hands such a task's targets here, and they
# run once, traced (trace-files.sh): one vitest run per kind (unit, integration), a forked
# worker per test file, each file's footprint attributed from its worker's reads, the
# modules vitest loaded for it and the run's shared reads (`enact trace run
# --attribution`). The wanted files' footprints go to ENACT_FOOTPRINT_DIR, each with its
# outcome (`"outcomes": true`; a failed or cut-short test is incomplete), so the passing
# tests of a failed shard still land.
# No targets: the job runs its whole suite (vitest-runner.sh: the unit suite, then the
# integration one), traced as one run when a wanted test is under the package.
# vitest-runner.sh readies node_modules and the workspace builds before it hands the
# targets here, so the traced run finds them, as generate-reach-map.sh builds before it
# traces: the footprints hold what the tests read, not a build.
#
# Not recorded: anything off Linux. `enact trace run` traces with eBPF, and off Linux it
# fails (there is no file tracer), so the tests run together, untraced. A run the tracer
# couldn't start (no map written) runs untraced.
#
# Env: ENACT_FOOTPRINT_DIR · ENACT_FOOTPRINT_TARGETS · ENACT_EXE, ENACT_BIN (as trace-files.sh)
set -uo pipefail

RUNNER=$1
shift
OUT=${ENACT_FOOTPRINT_DIR:?}
LISTED=${ENACT_FOOTPRINT_TARGETS:-}
unset ENACT_FOOTPRINT_DIR ENACT_FOOTPRINT_TARGETS

if [ "$(uname -s)" != Linux ]; then
  exec "$RUNNER" "$@"
fi

ROOT=$(git rev-parse --show-toplevel)
ENACT=${ENACT_EXE:-${ENACT_BIN:-$(command -v enact || true)}}
[ -n "$ENACT" ] || { echo "footprints.sh: no enact on PATH: put it there or set ENACT_BIN" >&2; exit 2; }
export ROOT ENACT

# wanted <test>: whether enact asked a footprint of the repository-relative test file
# (listed, or a test of it listed; no list: every test).
wanted() {
  [ -n "$LISTED" ] || return 0
  awk -v t="$1" '$0 == t || index($0, t "::") == 1 { found = 1; exit } END { exit !found }' "$LISTED"
}

# The tests vitest-runner.sh sends to its integration and migration modes.
INTEGRATION='^packages/cli/(test/integration/.*|src/.*\.integration)\.test\.ts$|\.postgres\.test\.ts$'
MIGRATION='^packages/cli/test/migration/.*\.test\.ts$'
# Task metadata is derived from the component's declared services. Port discovery
# variables describe every enve service, including ones this job never starts.
# The standalone recorder supplies SERVICE_DEPS for the services it traces itself.
DECLARED_SERVICES=${ENACT_FOOTPRINT_SERVICES-${SERVICE_DEPS:-}}
if [ "${ENACT_SERVICES_ACTIVE:-0}" = 1 ] && [ -z "$DECLARED_SERVICES" ]; then
  echo "footprints.sh: active services need declared recording services" >&2
  exit 1
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/enact-footprints.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# run_kind <name> <wanted> <services> [<target>...]: the targets (none: the whole suite),
# traced when wanted, else run as usual.
run_kind() {
  local name=$1 wanted=$2 services=$3
  shift 3
  if [ "$wanted" = 0 ]; then
    "$RUNNER" "$@"
    return
  fi
  local status=0
  echo "🎙️  [footprints] tracing ${*:+$# }$name test file(s) for enact's reach map, with $ENACT"
  SERVICE_DEPS=$services "$ROOT/helpers/trace/trace-files.sh" "$WORK/$name.json" "$@" || status=$?
  if [ ! -s "$WORK/$name.json" ]; then
    echo "⚠️  [footprints] the $name tests weren't traced: they run untraced" >&2
    "$RUNNER" "$@"
    return
  fi
  # Every target conservatively holds its task's services: even a unit-named file can
  # make real Redis connections. Filenames determine runner mode, never service usage.
  node -e '
    const fs = require("fs");
    const [from, to, listed, services] = process.argv.slice(1);
    const map = JSON.parse(fs.readFileSync(from, "utf8"));
    const list = listed ? fs.readFileSync(listed, "utf8").split("\n").filter(Boolean) : null;
    const wanted = (t) => !list || list.some((l) => l === t || l.startsWith(t + "::"));
    for (const target of Object.keys(map.targets || {})) {
      if (wanted(target)) continue;
      delete map.targets[target];
      if (map.target_service_deps) delete map.target_service_deps[target];
    }
    if (services) {
      for (const fp of Object.values(map.targets || {})) {
        fp.recorders = [...new Set([...(fp.recorders || []), "n8n-services/1"])];
      }
    }
    map.outcomes = true;
    fs.writeFileSync(to + ".part", JSON.stringify(map));
    fs.renameSync(to + ".part", to);
    for (const [target, fp] of Object.entries(map.targets || {})) {
      const complete = fp.outcome === undefined;
      console.log(`🎯 [footprints] recorded \x27${target}\x27 (${complete ? "complete" : "incomplete"})`);
    }
  ' "$WORK/$name.json" "$OUT/$name-${ENACT_SHARD_INDEX:-1}-$$.json" "$LISTED" "$services" || status=1
  return "$status"
}

# The whole suite: one run, traced when a listed test is under this package (no list: every
# test is wanted), against the services when the package has integration tests.
if [ $# -eq 0 ]; then
  PKG=$(realpath -m --relative-to="$ROOT" "$PWD")
  [ "$PKG" = . ] && PKG= || PKG=$PKG/
  WANTED=1
  if [ -n "$LISTED" ] && ! awk -v p="$PKG" 'index($0, p) == 1 { found = 1; exit } END { exit !found }' "$LISTED"; then
    WANTED=0
  fi
  run_kind suite "$WANTED" "$DECLARED_SERVICES"
  exit
fi

# The targets by kind, each run traced once if it holds a wanted test, else as usual.
UNIT=()
INTEGRATIONS=()
MIGRATIONS=()
UNIT_WANTED=0
INTEGRATION_WANTED=0
MIGRATION_WANTED=0
for target in "$@"; do
  spec=$(realpath -m --relative-to="$ROOT" "$PWD/${target%%::*}")
  if [[ $spec =~ $INTEGRATION ]]; then
    INTEGRATIONS+=("$target")
    wanted "$spec" && INTEGRATION_WANTED=1
  elif [[ $spec =~ $MIGRATION ]]; then
    MIGRATIONS+=("$target")
    wanted "$spec" && MIGRATION_WANTED=1
  else
    UNIT+=("$target")
    wanted "$spec" && UNIT_WANTED=1
  fi
done
if [ "$UNIT_WANTED$INTEGRATION_WANTED$MIGRATION_WANTED" = 000 ]; then
  exec "$RUNNER" "$@"
fi

status=0
[ ${#UNIT[@]} -eq 0 ] || run_kind unit "$UNIT_WANTED" "$DECLARED_SERVICES" "${UNIT[@]}" || status=$?
[ ${#INTEGRATIONS[@]} -eq 0 ] || run_kind integration "$INTEGRATION_WANTED" "$DECLARED_SERVICES" "${INTEGRATIONS[@]}" || status=$?
[ ${#MIGRATIONS[@]} -eq 0 ] || run_kind migration "$MIGRATION_WANTED" "$DECLARED_SERVICES" "${MIGRATIONS[@]}" || status=$?
exit "$status"

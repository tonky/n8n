#!/usr/bin/env bash
# ==============================================================================
# e2e-footprints.sh <spec...> - Runs Playwright e2e specs, recording their footprints
# ==============================================================================
# playwright-runner.sh hands its specs here (relative to the playwright package, as the
# job passes them) when enact wants footprints (ENACT_FOOTPRINT_DIR: `enact trace record`,
# every spec; `enact run` recording, the specs ENACT_FOOTPRINT_TARGETS lists). Each wanted
# spec runs alone through run-local-isolated.mjs: an n8n server started for it on its own
# SQLite database, so what the server and the browser did is that spec's (a server serving
# several specs would hand a later one what an earlier one loaded). Every Node.js process
# of its run records its reads (node-reads.mjs, preloaded through NODE_OPTIONS); then
# e2e-footprint.mjs writes the map into ENACT_FOOTPRINT_DIR, the editor's served outputs
# mapped to their sources (editor-chunks.mjs). The other specs run together, as usual.
# Exits non-zero when any spec failed; the passing specs' footprints land still.
#
# Env: ENACT_FOOTPRINT_DIR · ENACT_FOOTPRINT_TARGETS · ENACT_SHARD_INDEX
set -uo pipefail

TRACE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TRACE_DIR/../.." && pwd)"
PLAYWRIGHT_DIR="$REPO_ROOT/packages/quality/testing/playwright"
PACKAGE="${PLAYWRIGHT_DIR#"$REPO_ROOT"/}"
LISTED=${ENACT_FOOTPRINT_TARGETS:-}

wanted() { # <repository-relative spec>
  [ -n "$LISTED" ] || return 0
  awk -v t="$1" '$0 == t || index($0, t "::") == 1 { found = 1; exit } END { exit !found }' "$LISTED"
}

# run-local-isolated.mjs, waiting for n8n until it is ready (../n8n-ready.mjs).
# Its Playwright workers: the shard's CPUs (N8N_PW_WORKERS, ../playwright-runner.sh).
ISOLATED=(node --import "$TRACE_DIR/../n8n-ready.mjs" "$PLAYWRIGHT_DIR/scripts/run-local-isolated.mjs"
  ${N8N_PW_WORKERS:+--workers "$N8N_PW_WORKERS"})

RECORDED=()
UNRECORDED=()
for spec in "$@"; do
  if wanted "$PACKAGE/${spec#./}"; then RECORDED+=("${spec#./}"); else UNRECORDED+=("$spec"); fi
done

status=0
if [ ${#UNRECORDED[@]} -gt 0 ]; then
  "${ISOLATED[@]}" "${UNRECORDED[@]}" || status=$?
fi
[ ${#RECORDED[@]} -gt 0 ] || exit "$status"

# The editor's chunk map, kept beside the install (no footprint holds node_modules).
CHUNKS="$REPO_ROOT/node_modules/.enact-editor-chunks.json"
if ! ENACT_FOOTPRINT_ROOT="$REPO_ROOT" node "$TRACE_DIR/editor-chunks.mjs" "$CHUNKS"; then
  echo "❌ [e2e-footprints] the editor's build couldn't be mapped to its sources: the specs run unrecorded" >&2
  "${ISOLATED[@]}" "${RECORDED[@]}" || status=$?
  exit "$status"
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/enact-e2e-footprints.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
RESULTS=()
n=0
for spec in "${RECORDED[@]}"; do
  n=$((n + 1))
  echo "🎙️  [e2e-footprints] $n/${#RECORDED[@]}: $spec, on an n8n of its own"
  spec_status=0
  # Its results outside the checkout: a footprint holding what the run wrote would change
  # while it ran (enact lands no such footprint). The reporters replace the config's (an
  # html report, metrics): list, and playwright-attribution.mjs writing the tests it skipped
  # (skips/<n>.jsonl), so the footprint lands marked as skipped here.
  mkdir -p "$WORK/skips"
  ENACT_NODE_READS="$WORK/node/$n" ENACT_FOOTPRINT_ROOT="$REPO_ROOT" \
    NODE_OPTIONS="--import $TRACE_DIR/node-reads.mjs${NODE_OPTIONS:+ $NODE_OPTIONS}" \
    ENACT_SKIPS_FILE="$WORK/skips/$n.jsonl" \
    "${ISOLATED[@]}" "$spec" --output="$WORK/results/$n" \
    "--reporter=list,$TRACE_DIR/playwright-attribution.mjs" || spec_status=$?
  [ "$spec_status" -eq 0 ] || status=$spec_status
  RESULTS+=("$PACKAGE/$spec=$spec_status")
done

ENACT_FOOTPRINT_ROOT="$REPO_ROOT" node "$TRACE_DIR/e2e-footprint.mjs" write "$WORK" "$CHUNKS" "${RESULTS[@]}" || status=1
exit "$status"

#!/usr/bin/env bash
# A real command target: its nonempty partitions cover the complete SQLite migration suite.
set -euo pipefail
export LC_ALL=C
if [ "$#" -gt 1 ] || { [ "$#" = 1 ] && [ "$1" != scripts/check-migrations-sqlite.sh ]; }; then
  echo 'check-migrations-sqlite.sh: expected its own script target or no target' >&2
  exit 2
fi
cd "$(dirname "${BASH_SOURCE[0]}")/.."
files=()
collect_tests() {
  local file
  for file in "$1"/*; do
    if [ -d "$file" ]; then collect_tests "$file";
    elif [[ "$file" = *.test.ts ]] && [ -f "$file" ]; then files+=("$file"); fi
  done
}
collect_tests test/migration
if [ "${#files[@]}" = 0 ]; then
  echo 'check-migrations-sqlite.sh: no migration tests found' >&2
  exit 2
fi
# A missing allocation is conservative; a fractional allocation never rounds up to
# another concurrent worker. Strip leading zeroes without shell integer overflow.
cpus="${ENACT_WORKER_CPUS:-1}"
if ! [[ "$cpus" =~ ^[0-9]+([.][0-9]+)?$ ]] || ! [[ "$cpus" =~ [1-9] ]]; then
  echo 'check-migrations-sqlite.sh: ENACT_WORKER_CPUS must be positive' >&2
  exit 2
fi
whole="${cpus%%.*}"
whole="${whole#"${whole%%[!0]*}"}"
case "$whole" in
  ''|0|1) partitions=1 ;;
  2|3) partitions="$whole" ;;
  *) partitions=4 ;;
esac
[ "$partitions" -le "${#files[@]}" ] || partitions="${#files[@]}"
# The outer generic tracer records this entire command. No nested own recorder or
# cross-run transformed module cache may hide source reads from that capture.
unset ENACT_FOOTPRINT_DIR ENACT_FOOTPRINT_TARGETS ENACT_SHARD_INDEX ENACT_SHARD_TOTAL SHARD TOTAL_SHARDS
export VITEST_MIGRATION=1 DB_TYPE=sqlite DB_SQLITE_POOL_SIZE=4 VITEST_FS_CACHE=0 MAX_WORKERS=1
export NODE_OPTIONS="${NODE_OPTIONS:-} --max-old-space-size=2560"
pids=()
cleanup() {
  for pid in ${pids[@]+"${pids[@]}"}; do kill "$pid" 2>/dev/null || true; done
  wait || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
for ((partition=0; partition<partitions; partition++)); do
  batch=()
  for ((i=partition; i<${#files[@]}; i+=partitions)); do batch+=("${files[i]}"); done
  ../../helpers/vitest-runner.sh "${batch[@]}" & pids+=("$!")
done
status=0
for pid in ${pids[@]+"${pids[@]}"}; do wait "$pid" || status=$?; done
pids=()
exit "$status"

#!/usr/bin/env bash
# One real schema-docs script target drives both database dialect checks.
set -euo pipefail
if [ "$#" = 0 ]; then
  set -- scripts/schema-docs.mjs
fi
if [ "$#" != 1 ] || [ "$1" != scripts/schema-docs.mjs ] || [ ! -f "$1" ]; then
  echo 'schema-check.sh: expected the scripts/schema-docs.mjs target' >&2
  exit 2
fi
unset CI
status=0
node "$1" diff --db=sqlite || status=$?
node --import "${ENACT_RECORDERS_DIR:?}/js/testcontainers-enve-shim.mjs" "$1" diff --db=postgres || status=$?
exit "$status"

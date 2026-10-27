#!/usr/bin/env bash
# ==============================================================================
# build-workspace-deps.sh <turbo filter...> - Builds workspace packages when their sources changed
# ==============================================================================
# The tests, Playwright and the cli service import the workspace packages from their builds
# (`dist/`, git-ignored). This runs `turbo run build:unchecked` on the filters (`n8n^...`:
# what the cli package depends on; `n8n...`: it too), and turbo decides what builds: a
# package's task hash covers its sources (git's view: tracked and untracked files, not
# ignored ones), its dependencies' hashes, the lockfile and turbo.json. A package whose hash
# changed builds, and so do its dependents; the others are cache hits, whose outputs turbo
# rewrites only when they differ from the cached ones. An unchanged tree costs turbo's
# start (0.2-0.6 s); a checkout without turbo's cache builds once.
#
# Every run calls it: checking only whether a dist file exists would run tests against an
# edited dependency's stale build.
#
# One build at a time per checkout, under the env's flock: side-by-side shards (and the cli
# service) would build the same packages into the same dist; the second waits and finds them
# built. The kernel releases it when its holder dies, however it dies, and turbo runs without
# its descriptor (`-o`) so a background turbo daemon doesn't inherit and hold the lock.
#
# N8N_WORKSPACE_DEPS_BUILT=1 skips it: the runs a run starts once it built (a handed
# package's, footprints.sh's traced one), and generate-reach-map.sh, which builds up front,
# so a traced run records the tests' reads, not turbo's.
# ==============================================================================
set -euo pipefail
[ "${N8N_WORKSPACE_DEPS_BUILT:-}" = 1 ] && exit 0
[ $# -gt 0 ] || { echo "usage: build-workspace-deps.sh <turbo filter...>" >&2; exit 64; }

cd "$(dirname "${BASH_SOURCE[0]}")/.."
. helpers/pnpm-store.sh
filters=()
for filter in "$@"; do filters+=("--filter=$filter"); done
locks="/tmp/enact-locks-$(id -u)/$(pwd -P | cksum | cut -d ' ' -f 1)"
mkdir -p "$locks"
exec flock -o "$locks/workspace-build.flock" \
  pnpm turbo run build:unchecked "${filters[@]}" --output-logs=errors-only

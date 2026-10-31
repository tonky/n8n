package n8n

import (
	"enact.dev/schema"
	"n8n.io:enve"
)

let J = pipeline.#jobs

n8n: services: enve.profiles.dev.services & {
	postgres: enact: kind: "postgres"
	redis: enact: kind:    "redis"
	cli: enact: kind:      "http"
}

pipeline: schema.#Pipeline & {
	services: n8n.services
	// Local runs need --memory 8GiB for this Node heap and native tools.
	env: NODE_OPTIONS: "--max-old-space-size=6144"
	toolchain: node: {
		package_manager: "pnpm"
		env: {ELECTRON_SKIP_BINARY_DOWNLOAD: "1", GITHUB_TOKEN: ""}
	}
	ci: {
		no_cache: {labels: ["no-cache", "showcase"], branch_prefixes: ["showcase/"]}
		concurrency: max_parallel_jobs: 16
		remote_cache: {
			secrets: {bucket: "R2_BUCKET", access_key_id: "R2_ACCESS_KEY_ID", secret_access_key: "R2_SECRET_ACCESS_KEY"}
			public_url: "https://pub-30fd937eb7634039b8c49d49bfec91a9.r2.dev"
			public_key: "enve-r2-1:ckHPTeWVef6mba+1AwWHjKYCsUWKPfP9IXPm5YXNoHg="
		}
		budget: {enforce: true, untraced_tests: 10, wall_minutes: 30}
		workers: {
			standard: {
				labels: ["self-hosted", "Linux", "X64", "tonky-ci"], tier: "dedicated", available: 1, cost_per_min: 0.010
				pool: {
					cpus: 14, memory_mb: 28672
					sizes: {
						"tonky-ci-s": {cpus: 2, memory_mb: 4096}
						"tonky-ci-m": {cpus: 4, memory_mb: 8192}
						"tonky-ci-l": {cpus: 6, memory_mb: 13312}
					}
				}
			}
			arm64: {
				labels: ["self-hosted", "Linux", "ARM64", "tonky-ci"], tier: "dedicated", available: 1, cost_per_min: 0.008
				pool: {
					cpus: 4, memory_mb: 8192
					sizes: {
						"tonky-ci-s": {cpus: 2, memory_mb: 4096}
						"tonky-ci-m": {cpus: 4, memory_mb: 8192}
					}
				}
			}
		}
	}
	workflows: {
		ci: {
			layout: "staged", services: "on_demand"
			concurrency: {scope: "branch", cancel_in_progress: true}
			triggers: {
				push: branches:         ["main", "master", "perf/ci-modernization", "perf/ci-showcase"]
				pull_request: branches: ["main", "master", "perf/ci-modernization"]
			}
			stages: [
				{
					name: "check-and-lint"
					tasks: [
						{name: "Check workspace package integrity", command: "node scripts/check-workspace-private-deps.mjs"},
						{name: "Check module boundaries", command: "node scripts/check-boundaries.mjs"},
						{name: "Check formatting", command: "pnpm format:check"},
						{name: "Check packaging", command: "helpers/build-workspace-deps.sh --checked 'n8n-node-dev^...' && CI=true pnpm -r pack --dry-run"},
					]
					select: [J.lint, J.typecheck, J.schema_check], fail_fast: true, services: "on_demand"
				},
				{name: "test", matrix: true, select: [J.test, J.migrate, J.integration, J.dev_server_smoke], fail_fast: false, services: "on_demand"},
			]
		}
		local: {
			services: "on_demand"
			stages:   [{name: "dev", select: [J.test, J.migrate, J.integration, J.dev_server_smoke]}]
		}
	}
}

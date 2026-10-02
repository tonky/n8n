package n8n

import "enact.dev/schema"

let J = pipeline.#jobs

pipeline: schema.#Pipeline & {
	toolchain: node: {
		package_manager: "pnpm"
		env: ELECTRON_SKIP_BINARY_DOWNLOAD: "1"
	}
	ci: {
		no_cache: {
			labels: ["no-cache", "showcase"]
			branch_prefixes: ["showcase/"]
		}
		concurrency: {
			max_parallel_jobs: 16
		}
		workers: {
			"standard": {
				available:    8
				cost_per_min: 0.008
				cpus:         4.0
				labels: [
					"ubuntu-latest",
				]
				memory_mb: 14336
			}
			"4vcpu": {
				available:    4
				cost_per_min: 0.016
				cpus:         4.0
				labels: [
					"ubuntu-latest",
				]
				memory_mb: 16384
			}
		}
	}
	workflows: {
		ci: {
			layout:   "staged"
			services: "on_demand"
			concurrency: {
				scope:              "branch"
				cancel_in_progress: true
			}
			triggers: {
				push: {
					branches: ["main", "master", "perf/ci-modernization"]
				}
				pull_request: {
					branches: ["main", "master", "perf/ci-modernization"]
				}
			}
			stages: [
				{
					name: "check-and-lint"
					select: [J.lint, J.typecheck, J.pack, J.migrate, J.schema_check]
					tasks: [{
						name:    "Verify workspace package integrity"
						command: "pnpm boundaries:check && node scripts/check-workspace-private-deps.mjs"
					}]
					fail_fast: true
					services:  "on_demand"
				},
				{
					name:   "test"
					matrix: true
					select: [J.test, J.smoke]
					fail_fast: false
					services:  "on_demand"
				},
			]
		}
	}
}

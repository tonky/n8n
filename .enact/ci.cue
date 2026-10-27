package n8n

import "enact.dev/schema"

let J = pipeline.#jobs

pipeline: schema.#Pipeline & {
	// Local runs need --memory 8GiB for this Node heap and native tools.
	env: NODE_OPTIONS: "--max-old-space-size=6144"
	toolchain: node: {
		package_manager: "pnpm"
		env: {
			ELECTRON_SKIP_BINARY_DOWNLOAD: "1"
			// Install downloads are public. Do not send a local runner token.
			GITHUB_TOKEN: ""
		}
	}
	ci: {
		no_cache: {
			labels: ["no-cache", "showcase"]
			branch_prefixes: ["showcase/"]
		}
		concurrency: {
			max_parallel_jobs: 16
		}
		// The fork's jobs run on the user's tonky-ci fleet, one fresh container per job (enact's
		// .enact/workflows.cue workers `tonky-ci`, `tonky-ci-arm64`): stage jobs on the x86_64
		// slots, matrix rows on the cheapest slot they fit, so small ones take the arm64 slot.
		workers: {
			"standard": {
				labels: ["self-hosted", "Linux", "X64", "tonky-ci"]
				tier:         "dedicated"
				available:    2
				cost_per_min: 0.010
				cpus:         6
				memory_mb:    13312
			}
			"arm64": {
				labels: ["self-hosted", "Linux", "ARM64", "tonky-ci"]
				tier:         "dedicated"
				available:    1
				cost_per_min: 0.008
				cpus:         4
				memory_mb:    8192
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
					branches: ["main", "master", "perf/ci-modernization", "perf/ci-showcase"]
				}
				pull_request: {
					branches: ["main", "master", "perf/ci-modernization"]
				}
			}
			stages: [
				{
					name: "check-and-lint"
					tasks: [{
						name: "Check workspace package integrity"
						command: "node scripts/check-workspace-private-deps.mjs"
					}]
					select: [J.lint, J.typecheck, J.schema_check]
					fail_fast: true
					services:  "on_demand"
				},

				{
					name:   "test"
					matrix: true
					select: [J.test, J.migrate, J.integration]
					fail_fast: false
					services:  "on_demand"
				},
			]
		}
	}
}

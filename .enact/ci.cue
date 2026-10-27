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
		// The fork's jobs run on the user's tonky-ci fleet: one fresh container per job, x86_64
		// slots of 6 cpus and 13 GB (enact's .enact/workflows.cue worker `tonky-ci`).
		workers: "standard": {
			labels: ["self-hosted", "Linux", "X64", "tonky-ci"]
			tier:      "dedicated"
			available: 2
			cpus:      6
			memory_mb: 13312
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

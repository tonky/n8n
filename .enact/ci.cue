package n8n

pipeline: {
	ci: {
		concurrency: {
			max_parallel_jobs: 16
			max_total_shards:  32
		}
		strategy: "auto"
		workers: {
			"standard": {
				available:    8
				cost_per_min: 0.008
				cpus:         2.0
				labels: [
					"ubuntu-latest",
				]
				memory_mb: 7168
			}
			"4vcpu": {
				available:    4
				cost_per_min: 0.016
				cpus:         4.0
				labels: [
					"ubuntu-latest-4-cores",
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
					name:      "preflight"
					tasks:     ["fmt", "lint", "typecheck"]
					fail_fast: true
					services:  "disabled"
				},
				{
					name:      "test"
					tasks:     ["test"]
					fail_fast: false
					services:  "on_demand"
				},
			]
		}
	}
}

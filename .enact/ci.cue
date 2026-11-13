package n8n

import (
	"enact.dev/schema"
	"n8n.io:enve"
)

let J = pipeline.#jobs

n8n: services: enve.profiles.dev.services & {
	postgres: enact: kind: "postgres"
	redis: enact: kind:    "redis"
	kafka: enact: kind:    "kafka"
	mysql: enact: kind:    "mysql"
	cli: enact: kind:      "http"
	proxy: enact: kind:    "http"
}

pipeline: schema.#Pipeline & {
	services: n8n.services
	// Local runs need --memory 8GiB for this Node heap and native tools.
	env: NODE_OPTIONS: "--max-old-space-size=6144"
	toolchain: node: {
		package_manager: "pnpm"
		env: {ELECTRON_SKIP_BINARY_DOWNLOAD: "1", GITHUB_TOKEN: "", npm_config_build_from_source: "false"}
	}
	ci: {
		control_worker: "standard"
		soft_placement: {fallback_seconds: 15}
		scheduler: {makespan_tolerance: 1.05}
		history: {workflow: ".github/workflows/enact-ci.yml"}
		rerun: {labels: ["rerun", "showcase"], branch_prefixes: ["proof/", "showcase/proof/"]}
		allow_broad: branch_prefixes: ["mirror-broad/", "proof/", "showcase/proof/"]
		concurrency: max_parallel_jobs: 64
		remote_cache: {
			secrets: {bucket: "R2_BUCKET", access_key_id: "R2_ACCESS_KEY_ID", secret_access_key: "R2_SECRET_ACCESS_KEY"}
			public_url: "https://pub-30fd937eb7634039b8c49d49bfec91a9.r2.dev"
			public_key: "enve-r2-1:ckHPTeWVef6mba+1AwWHjKYCsUWKPfP9IXPm5YXNoHg="
			repo:       "tonky/n8n"
			branch:     "perf/ci-showcase"
		}
		budget: {enforce: true, untraced_tests: 20, wall_minutes: 30}
		workers: {
			github: {
				// Standard public-repository capacity; the quota is shared across images.
				preset: "github-public", labels: ["ubuntu-24.04"]
				tier: "on_demand", available: 20, cost_per_min: 0
				// Conservative estimate until a matching cold hosted canary calibrates it.
				setup_overhead_sec: 300
				timeout_minutes: 90
			}
			standard: {
				labels: ["self-hosted", "Linux", "X64", "tonky-ci"], host_id: "ibp8", tier: "dedicated", available: 1, throughput: 1.0, cost_per_min: 0.010, timeout_minutes: 90
				pool: {
					cpus: 14, memory_mb: 28672
					quantization: {
						label_prefix: "tonky-ci", cpu_step: 1, memory_step_mb: 1024
						runtime_reserve_mb: 2048
						// Retain the existing cold JavaScript setup floor during the canary.
						min: {cpus: 1, memory_mb: 4096}
						max: {cpus: 6, memory_mb: 13312}
						control: {cpus: 2, memory_mb: 4096}
					}
				}
			}
			arm64: {
				labels: ["self-hosted", "Linux", "ARM64", "tonky-ci", "mac1"], host_id: "mac1", tier: "dedicated", available: 1, throughput: 1.35, cost_per_min: 0.010, timeout_minutes: 90
				pool: {
					cpus: 16, memory_mb: 36864
					// mac1's dispatcher runs 4c/8G while a Mac lane or gate holds the host
					// (KNOWLEDGE `tonky-ci` load clamp): an l job would wait it out.
					floor: {cpus: 4, memory_mb: 8192}
					quantization: {
						label_prefix: "tonky-ci", cpu_step: 1, memory_step_mb: 1024
						runtime_reserve_mb: 2048
						min: {cpus: 1, memory_mb: 4096}
						max: {cpus: 6, memory_mb: 13312}
						control: {cpus: 2, memory_mb: 4096}
					}
				}
			}
			l7: {
				// A second X64 host (16t, ~13 GiB free), up to 6c/13G allocations when idle.
				// A gate lane holding l7 drains its dispatcher to zero.
				labels: ["self-hosted", "Linux", "X64", "tonky-ci"], host_id: "l7", tier: "dedicated", available: 1, throughput: 0.95, cost_per_min: 0.006, timeout_minutes: 90
				pool: {
					cpus: 16, memory_mb: 13312
					quantization: {
						label_prefix: "tonky-ci", cpu_step: 1, memory_step_mb: 1024
						runtime_reserve_mb: 2048
						min: {cpus: 1, memory_mb: 4096}
						max: {cpus: 6, memory_mb: 13312}
						control: {cpus: 2, memory_mb: 4096}
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
				pull_request: branches: ["main", "master", "perf/ci-modernization", "perf/ci-showcase"]
			}
			stages: [{
				name: "test", matrix: true
				select: [J.lint, J.typecheck, J.schema_check, J.test, J.migrate, J.migrate_sqlite, J.integration, J.dev_server_smoke]
				fail_fast: false, services: "on_demand"
			}]
		}
		local: {
			services: "on_demand"
			stages:   [{name: "dev", select: [J.test, J.migrate, J.migrate_sqlite, J.integration, J.dev_server_smoke]}]
		}
	}
}

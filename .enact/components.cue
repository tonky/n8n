package n8n

pipeline: {
	name:        "n8n-platform"
	description: "n8n Workflow Automation Platform (enact + enve accelerated)"

	workspace_scope: {
		ignore: [
			".agents",
			".claude",
			".github",
			"assets",
			"docker",
			"docs",
			"security",
			"*.md",
		]
		include: [
			".enact",
			"cue.mod",
			"enve.cue",
			"enve.lock",
			"bin",
			"helpers",
			"patches",
			"scripts",
			"packages/workflow",
			"packages/testing/containers",
			"packages/testing/janitor",
			"packages/@n8n",
			"package.json",
			"pnpm-lock.yaml",
			"pnpm-workspace.yaml",
			"turbo.json",
			"tsconfig.json",
			"biome.jsonc",
		]
	}

	caches: {
		tsbuildinfo_frontend: {
			path: "packages/frontend/editor-ui/node_modules/.cache/vue-tsc.tsbuildinfo"
			key: "tsbuildinfo-frontend-${{ runner.os }}-${{ hashFiles('packages/frontend/editor-ui/src/**') }}"
			restore_keys: [
				"tsbuildinfo-frontend-${{ runner.os }}-",
			]
			tier: "tiered"
			mode: "read_write"
		}
		tsbuildinfo_cli: {
			path: "packages/cli/node_modules/.cache/tsbuildinfo"
			key: "tsbuildinfo-cli-${{ runner.os }}-${{ hashFiles('packages/cli/src/**') }}"
			restore_keys: [
				"tsbuildinfo-cli-${{ runner.os }}-",
			]
			tier: "tiered"
			mode: "read_write"
		}
		sqlite_e2e_template: {
			path: "/tmp/n8n-e2e-template"
			key: "sqlite-template-v2-${{ runner.os }}-${{ hashFiles('packages/@n8n/db/src/migrations/**') }}"
			restore_keys: [
				"sqlite-template-v2-${{ runner.os }}-",
			]
			tier: "tiered"
			mode: "read_write"
		}
	}

	components: {
		core: {
			name:        "@n8n/core"
			title:       "n8n Core Workflow Engine"
			root:        "packages/core"
			watch_paths: ["packages/core/**"]
			depends_on:  []
			workspace_scope: {
				include_dependencies: true
			}
			target_scope: {
				fallback: "all"
				rules: [{
					match: ["packages/core/**/*.ts"]
					engine: "typescript"
				}]
			}
			lint: {
				command: "pnpm exec biome check {relative_changed_files}"
				filter: {
					include: ["**/*.{ts,tsx,js,jsx,json,jsonc}"]
					on_empty: "skip"
				}
			}
			typecheck: {
				command: "../../helpers/typecheck-runner.sh"
			}
			pack: {
				command: "pnpm exec publint || pnpm pack --dry-run"
			}
			test: {
				command: "./node_modules/.bin/vitest run {relative_targets}"
			}
		}

		db: {
			name:        "@n8n/db"
			title:       "n8n Database & Entities"
			root:        "packages/@n8n/db"
			watch_paths: ["packages/@n8n/db/**"]
			depends_on:  [components.core]
			workspace_scope: {
				include_dependencies: true
			}
			services: [n8n.services.postgres]
			target_scope: {
				fallback: "all"
				rules: [{
					match: ["packages/@n8n/db/**/*.ts"]
					engine: "typescript"
				}]
			}
			lint: {
				command: "pnpm exec biome check {relative_changed_files}"
				filter: {
					include: ["**/*.{ts,tsx,js,jsx,json,jsonc}"]
					on_empty: "skip"
				}
			}
			typecheck: {
				command: "../../../helpers/typecheck-runner.sh"
			}
			pack: {
				command: "pnpm exec publint || pnpm pack --dry-run"
			}
			schema_check: {
				command: "../../../helpers/check-postgres-schema.mjs"
			}
			test: {
				command: "node scripts/generate-migration-index.mjs && ../../../helpers/vitest-runner.sh {relative_targets}"
			}
		}

		cli: {
			name:        "cli"
			title:       "n8n CLI & Backend Service"
			root:        "packages/cli"
			watch_paths: ["packages/cli/**"]
			depends_on:  [components.core, components.db, components.nodes_base]
			workspace_scope: {
				include_dependencies: true
			}
			services: [n8n.services.postgres, n8n.services.redis]
			service:  n8n.services.cli
			target_scope: {
				fallback: "all"
				rules: [{
					match: ["packages/cli/**/*.ts"]
					engine: "typescript"
				}]
			}
			lint: {
				command: "pnpm exec biome check {relative_changed_files}"
				filter: {
					include: ["**/*.{ts,tsx,js,jsx,json,jsonc}"]
					on_empty: "skip"
				}
			}
			typecheck: {
				command: "../../helpers/typecheck-runner.sh"
			}
			pack: {
				command: "pnpm exec publint || pnpm pack --dry-run"
			}
			migrate: {
				command: "pnpm test:postgres:migrations"
			}
			test: {
				command: "../../helpers/vitest-runner.sh {relative_targets}"
			}
		}

		frontend: {
			name:        "frontend"
			title:       "n8n Frontend Editor UI"
			root:        "packages/frontend/editor-ui"
			watch_paths: ["packages/frontend/**"]
			depends_on:  [components.core]
			workspace_scope: {
				include: [
					"packages/frontend",
					"packages/modules",
				]
				include_dependencies: true
			}
			target_scope: {
				fallback: "all"
				rules: [{
					match: ["packages/frontend/**/*.{ts,vue}"]
					engine: "typescript"
				}]
			}
			tasks: {
				lint: {
					command: "pnpm exec oxlint {relative_changed_files} --quiet"
					filter: {
						include: ["**/*.{ts,tsx,js,jsx,json,jsonc,vue}"]
						on_empty: "skip"
					}
				}
				typecheck: {
					command: "../../../helpers/typecheck-runner.sh"
				}
			}
			test: {
				command: "../../../helpers/vitest-runner.sh {relative_targets}"
			}
		}

		nodes_base: {
			name:        "nodes-base"
			title:       "n8n Community & Base Integration Nodes"
			root:        "packages/nodes-base"
			watch_paths: ["packages/nodes-base/**"]
			depends_on:  [components.core]
			workspace_scope: {
				include_dependencies: true
			}
			target_scope: {
				fallback: "all"
				rules: [{
					match: ["packages/nodes-base/**/*.ts"]
					engine: "typescript"
				}]
			}
			lint: {
				command: "pnpm exec biome check {relative_changed_files}"
				filter: {
					include: ["**/*.{ts,tsx,js,jsx,json,jsonc}"]
					on_empty: "skip"
				}
			}
			typecheck: {
				command: "../../helpers/typecheck-runner.sh"
			}
			test: {
				command: "./node_modules/.bin/vitest run {relative_targets}"
			}
		}

		playwright: {
			name:        "playwright"
			title:       "n8n End-to-End Playwright Suite"
			root:        "packages/testing/playwright"
			watch_paths: ["packages/testing/playwright/**"]
			depends_on:  []
			workspace_scope: {
				include: [
					"packages/testing",
					"packages/cli",
					"packages/frontend",
					"packages/modules",
					"packages/nodes-base",
					"packages/workflow",
					"packages/core",
					"packages/@n8n/db",
				]
				include_dependencies: true
			}
			services: [n8n.services.postgres, n8n.services.redis, n8n.services.cli]
			target_scope: {
				fallback: "all"
				rules: [{
					match: ["packages/testing/playwright/**/*.{ts,js,mjs}"]
					engine: "typescript"
				}]
			}
			resources: {
				cpus:      4.0
				memory_mb: 10240
			}
			smoke: {
				command: "pnpm test:dev-server-smoke"
			}
			test: {
				command: "../../../helpers/playwright-runner.sh {relative_targets}"
			}
		}
	}
}

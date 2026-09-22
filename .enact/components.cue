package n8n

pipeline: {
	name:        "n8n-platform"
	description: "n8n Workflow Automation Platform (enact + enve accelerated)"

	workspace_scope: {
		include: [
			".enact",
			"bin",
			"helpers",
			"patches",
			"scripts",
			"packages/@n8n",
			"packages/core",
			"packages/workflow",
			"packages/testing/containers",
			"packages/testing/janitor",
			"package.json",
			"pnpm-lock.yaml",
			"pnpm-workspace.yaml",
			"turbo.json",
			"tsconfig.json",
			"biome.jsonc",
		]
	}

	components: {
		"@n8n/core": {
			name:        "@n8n/core"
			title:       "n8n Core Workflow Engine"
			technology:  "typescript"
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
				command: "pnpm exec biome check ."
			}
			typecheck: {
				command: "../../helpers/typecheck-runner.sh"
			}
			test: {
				command: "./node_modules/.bin/vitest run {relative_targets}"
			}
		}

		"@n8n/db": {
			name:        "@n8n/db"
			title:       "n8n Database & Entities"
			technology:  "typescript"
			root:        "packages/@n8n/db"
			watch_paths: ["packages/@n8n/db/**"]
			depends_on:  ["@n8n/core"]
			workspace_scope: {
				include_dependencies: true
			}
			services: {
				postgres: {
					name:     "postgres"
					port:     5432
					database: "n8n"
				}
			}
			target_scope: {
				fallback: "all"
				rules: [{
					match: ["packages/@n8n/db/**/*.ts"]
					engine: "typescript"
				}]
			}
			lint: {
				command: "pnpm exec biome check ."
			}
			typecheck: {
				command: "../../../helpers/typecheck-runner.sh"
			}
			test: {
				command: "node scripts/generate-migration-index.mjs && ../../../helpers/vitest-runner.sh {relative_targets}"
			}
		}

		"cli": {
			name:        "cli"
			title:       "n8n CLI & Backend Service"
			technology:  "typescript"
			root:        "packages/cli"
			watch_paths: ["packages/cli/**"]
			depends_on:  ["@n8n/core", "@n8n/db", "nodes-base"]
			workspace_scope: {
				include_dependencies: true
			}
			services: {
				postgres: {
					name:     "postgres"
					port:     5432
					database: "n8n"
				}
				redis: {
					name: "redis"
					port: 6379
				}
			}
			target_scope: {
				fallback: "all"
				rules: [{
					match: ["packages/cli/**/*.ts", "packages/@n8n/db/**/*.ts"]
					engine: "typescript"
				}]
			}
			lint: {
				command: "pnpm exec biome check ."
			}
			typecheck: {
				command: "../../helpers/typecheck-runner.sh"
			}
			test: {
				command: "../../helpers/vitest-runner.sh {relative_targets}"
			}
		}

		"frontend": {
			name:        "frontend"
			title:       "n8n Frontend Editor UI"
			technology:  "typescript"
			root:        "packages/frontend/editor-ui"
			watch_paths: ["packages/frontend/**"]
			depends_on:  ["@n8n/core"]
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
			lint: {
				command: "pnpm exec biome check ."
			}
			typecheck: {
				command: "../../../helpers/typecheck-runner.sh"
			}
			test: {
				command: "../../../helpers/vitest-runner.sh {relative_targets}"
			}
		}

		"nodes-base": {
			name:        "nodes-base"
			title:       "n8n Community & Base Integration Nodes"
			technology:  "typescript"
			root:        "packages/nodes-base"
			watch_paths: ["packages/nodes-base/**"]
			depends_on:  ["@n8n/core"]
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
				command: "pnpm exec biome check ."
			}
			typecheck: {
				command: "../../helpers/typecheck-runner.sh"
			}
			test: {
				command: "./node_modules/.bin/vitest run {relative_targets}"
			}
		}

		"playwright": {
			name:        "playwright"
			title:       "n8n End-to-End Playwright Suite"
			technology:  "playwright"
			root:        "packages/testing/playwright"
			watch_paths: ["packages/testing/playwright/**"]
			depends_on:  ["@n8n/core", "cli", "frontend", "nodes-base"]
			workspace_scope: {
				include: [
					"packages/testing",
					"packages/cli",
					"packages/frontend",
					"packages/nodes-base",
					"packages/workflow",
					"packages/core",
				]
				include_dependencies: true
			}
			services: {
				postgres: {
					name:     "postgres"
					port:     5432
					database: "n8n"
				}
				redis: {
					name: "redis"
					port: 6379
				}
			}
			target_scope: {
				fallback: "all"
				rules: [{
					match: ["packages/testing/playwright/**/*.{ts,js,mjs}"]
					engine: "typescript"
				}]
			}
			test: {
				command: "../../../helpers/playwright-runner.sh {relative_targets}"
			}
		}
	}
}

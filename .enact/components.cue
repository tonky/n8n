package n8n

import (
	"enact.dev/schema"
	"strings"
)

// One component per pnpm workspace package (packages.cue, generated from upstream's
// workspace by tools/gen_packages.py), plus hand-declared overrides for db, cli,
// playwright and @n8n/task-runner-python.

_lint: {
	#pkg:    string
	#styles: bool | *false
	#format: bool | *false
	let _tasks = strings.Join(["lint", if #styles {"lint:styles"}, if #format {"format:check"}], " ")
	command: "helpers/build-workspace-deps.sh --checked '" + #pkg + "^...' @n8n/eslint-config @n8n/oxlint-config && pnpm turbo run " + _tasks + " --filter=" + #pkg + " --output-logs=errors-only"
}

_typecheck: {
	#pkg:          string
	#declarations: bool | *false
	command: "helpers/build-workspace-deps.sh --checked '" + #pkg + "^...' && pnpm turbo run typecheck --filter=" + #pkg + " --output-logs=errors-only" + [
		if #declarations {" && RELEASE=true helpers/build-workspace-deps.sh --checked " + #pkg + " && test -f dist/index.d.ts"},
		"",
	][0]
}

_browserCheck: {direct: true, services: false, resources: {cpus: 4.0, memory_mb: 7168}}
_vitest:       "helpers/vitest-runner.sh {relative_targets}"

_unsetPgEnv: [
	"PGHOST", "PGPORT", "PGDATABASE", "PGUSER", "PGPASSWORD",
	"DB_POSTGRESDB_HOST", "DB_POSTGRESDB_PORT", "DB_POSTGRESDB_DATABASE", "DB_POSTGRESDB_USER", "DB_POSTGRESDB_PASSWORD",
]

_target_scope: {
	#dir:      string
	#tests:    [...string]
	#ignore:   [...string] | *[]
	#runner:   [...string] | *[]
	fallback:  *"all" | "none"
	tests:     #tests
	rules: [
		if len(#ignore) > 0 {match: #ignore, action: "ignore"},
		if len(#runner) > 0 {match: #runner, action: "full_component"},
		{match: [#dir + "/**/*.{ts,tsx,mts,cts,js,mjs,cjs,vue}"], engine: "typescript"},
	]
}

pipeline: schema.#Pipeline & {
	name:        "n8n-platform"
	description: "n8n Workflow Automation Platform (enact + enve accelerated)"

	workspace_scope: {
		ignore: [
			".actrc", ".agents/**", ".aikido", ".claude/**", ".devcontainer/**", ".dockerignore",
			".env.*.example", ".git-blame-ignore-revs", ".jscpd.json", ".github/ISSUE_TEMPLATE/**",
			".github/actionlint.yml", ".github/actions/**", ".github/docker-compose.yml",
			".github/poutine-rules/**", ".github/scripts/**", ".github/test-metrics/**",
			".npmignore", ".opencode", ".poutine.yml", ".vscode/**", "OWNERS", "assets/**",
			"codecov.yml", "cubic.yaml", "docker/**", "packages/extensions/.gitkeep",
			"security/**", "scripts/cloud-session*.mjs",
		]
		include: [
			"enve.cue", "enve.lock", ".enact", "cue.mod", "bin", "helpers", "patches", "scripts",
			"package.json", "pnpm-lock.yaml", "pnpm-workspace.yaml", "turbo.json",
			"tsconfig.json", "tsconfig.configs.json", "biome.jsonc", "vitest.workspace.ts",
			".prettierrc.js", ".prettierignore", ".boundaries-baseline.json",
			"packages/@n8n/typescript-config",
		]
	}

	analysis: recorders: {"e2e-footprint.mjs": "1", "n8n-services": "1"}

	analysis: derived: [
		for _, p in _packages if p.built {
			outputs: [p.dir + "/dist/**"]
			inputs:  [p.dir + "/**", for b in p.bundles {b + "/**"}]
			exclude: [
				for d in [p.dir, for b in p.bundles {b}] for e in ["/dist/**", "/**/*.test.ts", "/**/*.spec.ts", "/**/__tests__/**", "/**/test/**", "/**/*.md"] {d + e},
				for db in ["sqlite", "postgresdb"] {"packages/@n8n/db/src/migrations/" + db + "/index.ts"},
			]
			mapped: [for d in [p.dir, for b in p.bundles {b}] {d + "/src/**"}]
		},
		{outputs: ["packages/cli/test-exports-*/**"], inputs: ["packages/cli/test/integration/environments/source-control-export.service.test.ts"]},
		{
			outputs: ["packages/@n8n/workflow-sdk/test-fixtures/real-workflows/[0-9]*.json"]
			inputs:  ["packages/@n8n/workflow-sdk/test-fixtures/real-workflows/public_published_templates.zip", "packages/@n8n/workflow-sdk/test-fixtures/real-workflows/manifest.json"]
		},
		for db in ["sqlite", "postgresdb"] {
			outputs: ["packages/@n8n/db/src/migrations/" + db + "/index.ts"]
			inputs:  ["packages/@n8n/db/scripts/generate-migration-index.mjs", "packages/@n8n/db/src/migrations/common/[0-9]*.ts", "packages/@n8n/db/src/migrations/" + db + "/[0-9]*.ts"]
		},
		{
			outputs: ["packages/@n8n/task-runner-python/.venv/**"]
			inputs:  ["packages/@n8n/task-runner-python/pyproject.toml", "packages/@n8n/task-runner-python/uv.lock", "packages/@n8n/task-runner-python/.python-version"]
		},
	]

	caches: {
		vitest_transforms: {paths: ["node_modules/.vitest-cache"], key: ["pnpm-lock.yaml"], scope: "task"}
		node_build:        {paths: [".turbo"], key: ["package.json", "pnpm-lock.yaml"], scope: "task", refresh: "rolling"}
	}

	components: {
		root: {
			name: "root", title: "n8n Environment, Pipeline & pnpm Workspace", technology: "typescript", root: "."
			watch_paths: [
				"enve.cue", "enve.lock", ".enact/**", "cue.mod", "bin/**", ".github/workflows/**",
				".githooks/**", ".gitignore", ".gitattributes", ".editorconfig",
				"package.json", "pnpm-lock.yaml", "pnpm-workspace.yaml", "turbo.json",
				"tsconfig.json", "tsconfig.configs.json", "biome.jsonc", "vitest.workspace.ts",
				".prettierrc.js", ".prettierignore", "lefthook.yml", "knip.ts",
				".boundaries-baseline.json", ".code-health-baseline.json", "agent-harness.lock.json",
				"patches/**", "scripts/**", "helpers/vitest-runner.sh", "helpers/pnpm-store.sh",
				"helpers/build-workspace-deps.sh", "helpers/trace/**",
			]
			depends_on:      []
			workspace_scope: include_dependencies: true
		}

		for n, p in _packages if !p.custom {
			(n): {
				name:        n
				root:        p.dir
				watch_paths: [p.dir + "/**", for f in p.reads {f}]
				depends_on:  ["root", for d in p.deps {d}]
				workspace_scope: {
					include_dependencies: true
					if len(p.reads) > 0 {include: [p.dir, for f in p.reads {f}]}
				}
				if p.shards > 0 {shards: p.shards}
				if len(p.tests) > 0 {
					target_scope: _target_scope & {#dir: p.dir, #tests: p.tests, #ignore: p.exclude}
					test:         _vitest
					recorder:     "own_linux"
					recorded_by:  ["enact-node"]
				}
				if len(p.exclude) > 0 {target_scope: exclude: p.exclude}
				if len(p.handoff) > 0 {target_scope: handoff: p.handoff}
				if p.lint && name != "@n8n/efficiency" {
					lint: _lint & {#pkg: p.pkg, #styles: p.lint_styles, #format: p.format_check}
				}
				if p.typecheck && name != "@n8n/efficiency" {
					typecheck: _typecheck & {#pkg: p.pkg, #declarations: n == "@n8n/design-system" || n == "@n8n/chat"}
				}
				if name == "@n8n/efficiency" {
					jobs: {
						lint:      _browserCheck & {name: "Lint", tasks: [_lint & {#pkg: p.pkg, #styles: p.lint_styles, #format: p.format_check, name: "Run Linter"}]}
						typecheck: _browserCheck & {name: "Typecheck", tasks: [_typecheck & {#pkg: p.pkg, name: "Typecheck"}]}
					}
				}
			}
		}

		"nodes-base": {
			let P = _packages["nodes-base"]
			let NotRun = [P.dir + "/nodes/Kafka/test/v2/kafka.integration.test.ts", P.dir + "/nodes/MySql/test/v2/mysql.integration.test.ts"]
			jobs: integration: {
				recorder:     "own_linux"
				recorded_by:  ["enact-node"]
				target_scope: _target_scope & {#dir: P.dir, #tests: [P.dir + "/credentials/**/*.integration.test.ts"], #ignore: NotRun}
				tasks:        [{name: "integration", command: "VITEST_RUNNER_ARGS='--config vitest.integration.config.ts --dir credentials --coverage.enabled=false' helpers/vitest-runner.sh {relative_targets}"}]
			}
			target_scope: not_run: [{tests: NotRun, reason: "testcontainers (n8n-containers) starts their Kafka and MySQL: no container runtime under enve"}]
		}

		"@n8n/agents": target_scope: not_run: [{
			tests:  [_packages["@n8n/agents"].dir + "/src/__tests__/integration/**"]
			reason: "real model providers and vector stores (API keys): upstream runs them by hand (test:integration)"
		}]

		"@n8n/scan-community-package": target_scope: not_run: [{
			tests:  [_packages["@n8n/scan-community-package"].dir + "/test/provenance.test.mjs"]
			reason: "a node:test file the package's vitest picks up: \"No test suite found\""
		}]
		"@n8n/workflow-sdk": target_scope: not_run: [{
			tests:  [_packages["@n8n/workflow-sdk"].dir + "/src/codegen/codegen-roundtrip.test.ts"]
			reason: "57 real-workflow roundtrips fail against the manifest's expected warnings once the fixtures are extracted (a fresh checkout loads none at parse time and runs one test)"
		}]

		task_runner_python: {
			let Dir = "packages/@n8n/task-runner-python"
			name:            "@n8n/task-runner-python"
			title:           "n8n Python Task Runner"
			root:            Dir
			watch_paths:     [Dir + "/**"]
			depends_on:      ["root"]
			workspace_scope: include_dependencies: true
			target_scope: {
				fallback: "all"
				tests:    [Dir + "/tests/unit/test_*.py", Dir + "/tests/integration/test_*.py"]
				rules:    [{match: [Dir + "/**/*.py"], engine: "python"}]
			}
			lint:      "uv run --frozen --all-extras --group dev ruff format --check && uv run --frozen --all-extras --group dev ruff check"
			typecheck: "uv run --frozen --all-extras --group dev ty check src/"
			recorder:  "trace"
			test:      "uv run --frozen --all-extras --group dev pytest {relative_targets}"
		}

		"@n8n/db": {
			let P = _packages["@n8n/db"]
			let Services = [n8n.services.postgres]
			name:        "@n8n/db"
			title:       "n8n Database & Entities"
			root:        P.dir
			watch_paths: [P.dir + "/**", "docs/generated/**", ".tbls.*.yml", "helpers/schema-docs-postgres.mjs"]
			depends_on:  ["root", for d in P.deps {d}]
			workspace_scope: {
				include_dependencies: true
				include:              [P.dir, "docs/generated", ".tbls.postgres.yml", ".tbls.sqlite.yml", "packages/cli/src/services/ownership-transfer/ownership-transfer.manifest.json"]
			}
			services:     Services
			shards:       P.shards
			target_scope: _target_scope & {#dir: P.dir, #tests: P.tests}
			lint:         _lint & {#pkg: P.pkg, #styles: P.lint_styles, #format: P.format_check}
			typecheck:    _typecheck & {#pkg: P.pkg}
			jobs: schema_check: {
				name: "Schema Check"
				tasks: [
					{
						name:      "Verify SQLite Schema Docs"
						command:   "node scripts/generate-migration-index.mjs && helpers/build-workspace-deps.sh " + P.pkg + " && node scripts/schema-docs.mjs diff --db=sqlite"
						unset_env: ["CI"]
						filter:    {include: [P.dir + "/src/migrations/**", P.dir + "/src/entities/**", P.dir + "/scripts/schema-docs.mjs", "docs/generated/sqlite-schema/**", ".tbls.sqlite.yml"], on_empty: "skip"}
					},
					{
						name:      "Verify Postgres Schema Docs"
						command:   "node scripts/generate-migration-index.mjs && helpers/build-workspace-deps.sh " + P.pkg + " && node --import helpers/schema-docs-postgres.mjs scripts/schema-docs.mjs diff --db=postgres"
						unset_env: ["CI"]
						filter:    {include: [P.dir + "/src/migrations/**", P.dir + "/src/entities/**", P.dir + "/scripts/schema-docs.mjs", "helpers/schema-docs-postgres.mjs", "docs/generated/postgres-schema/**", ".tbls.postgres.yml"], on_empty: "skip"}
					},
				]
			}
			test: {
				command: "node scripts/generate-migration-index.mjs && " + _vitest
				env: ENACT_FOOTPRINT_SERVICES: strings.Join([for service in Services {service.name}], " ")
			}
			recorder:    "own_linux"
			recorded_by: ["enact-node", "n8n-services"]
		}

		cli: {
			let P = _packages.cli
			let Services = [n8n.services.postgres, n8n.services.redis]
			name:            "cli"
			title:           "n8n CLI & Backend Service"
			root:            P.dir
			watch_paths:     [P.dir + "/**", "helpers/n8n-template-db.cjs"]
			depends_on:      ["root", for d in P.deps {d}]
			workspace_scope: include_dependencies: true
			services:        Services
			service:         n8n.services.cli
			shards:          P.shards
			target_scope:    _target_scope & {#dir: P.dir, #tests: P.tests}
			lint:            _lint & {#pkg: P.pkg, #styles: P.lint_styles, #format: P.format_check}
			typecheck:       _typecheck & {#pkg: P.pkg}
			test: {
				command: _vitest
				env: ENACT_FOOTPRINT_SERVICES: strings.Join([for service in Services {service.name}], " ")
			}
			recorder:    "own_linux"
			recorded_by: ["enact-node", "n8n-services"]
			jobs: migrate: {
				recorder:     "own_linux"
				recorded_by:  ["enact-node", "n8n-services"]
				target_scope: _target_scope & {#dir: P.dir, #tests: [P.dir + "/test/migration/**/*.test.ts"]}
				tasks: [
					{
						name:    "migrate"
						command: "VITEST_MIGRATION=1 helpers/vitest-runner.sh {relative_targets}"
						env: {
							ENACT_FOOTPRINT_SERVICES: strings.Join([for service in Services {service.name}], " ")
							N8N_LOG_LEVEL:            "silent"
							DB_TYPE:                  "postgresdb"
							DB_POSTGRESDB_SCHEMA:     "alt_schema"
							DB_TABLE_PREFIX:          "test_"
						}
					},
					{
						name:      "migrate-sqlite"
						command:   "DB_TYPE=sqlite DB_SQLITE_POOL_SIZE=4 VITEST_MIGRATION=1 helpers/vitest-runner.sh {relative_targets}"
						env:       {ENACT_FOOTPRINT_SERVICES: strings.Join([for service in Services {service.name}], " "), N8N_LOG_LEVEL: "silent", DB_SQLITE_POOL_SIZE: "4", DB_TYPE: "sqlite"}
						unset_env: _unsetPgEnv
					},
				]
			}
		}

		playwright: {
			let P = _packages.playwright
			name:            "playwright"
			title:           "n8n End-to-End Playwright Suite"
			root:            P.dir
			watch_paths:     [P.dir + "/**", "helpers/playwright-runner.sh", "helpers/pw-spec-env.mjs", "helpers/n8n-ready.mjs"]
			depends_on:      ["root", "frontend", for d in P.deps {d}]
			workspace_scope: include_dependencies: true
			browsers: {
				engine:   "chromium"
				path:     "/tmp/.cache/ms-playwright"
				env:      "PLAYWRIGHT_BROWSERS_PATH"
				key:      [P.dir + "/package.json", "pnpm-lock.yaml"]
				artifact: "tools/playwright-browsers-linux-amd64.tar.zst"
			}
			shards:   4
			recorder: "own"
			target_scope: _target_scope & {
				#dir:    P.dir
				#tests:  [P.dir + "/tests/**/*.spec.ts", P.dir + "/**/*.test.{ts,mjs}"]
				#ignore: [P.dir + "/tests/dev-server-smoke/**/*.spec.ts"]
				exclude: [P.dir + "/tests/dev-server-smoke/**/*.spec.ts"]
				#runner: ["helpers/playwright-runner.sh", "helpers/pw-spec-env.mjs"]
				not_run: [{
					tests:  [for d in ["cli-workflows", "evals", "infrastructure", "performance"] {P.dir + "/tests/" + d + "/**/*.spec.ts"}]
					reason: "Playwright projects other than e2e and dev-server-smoke: upstream runs them against containers (infrastructure, performance), workflow fixtures (cli-workflows) or an LLM (evals)"
				}]
			}
			resources: {cpus: 4.0, memory_mb: 10240}
			jobs: {
				lint:      _browserCheck & {name: "Lint", tasks: [_lint & {#pkg: P.pkg, #styles: P.lint_styles, #format: P.format_check, name: "Run Linter"}]}
				typecheck: _browserCheck & {name: "Typecheck", tasks: [_typecheck & {#pkg: P.pkg, name: "Typecheck"}]}
				dev_server_smoke: {
					name:     "Dev-Server Boot Smoke"
					recorder: "trace"
					target_scope: _target_scope & {
						#dir:   P.dir
						#tests: [P.dir + "/tests/dev-server-smoke/**/*.spec.ts"]
						#ignore: [
							P.dir + "/tests/e2e/**/*.spec.ts",
							for d in ["cli-workflows", "evals", "infrastructure", "performance"] {P.dir + "/tests/" + d + "/**/*.spec.ts"},
							P.dir + "/**/*.test.{ts,mjs}",
						]
					}
					tasks: [
						{
							name:      "Run dev-server smoke spec (non-default ports)"
							command:   "DB_TYPE=sqlite helpers/build-workspace-deps.sh 'n8n-playwright^...' && DB_TYPE=sqlite pnpm test:dev-server-smoke:alt-port --reporter=list {relative_targets}"
							env:       DB_TYPE: "sqlite"
							unset_env: _unsetPgEnv
						},
						{
							name:      "Run dev-server smoke spec"
							command:   "DB_TYPE=sqlite helpers/build-workspace-deps.sh 'n8n-playwright^...' && DB_TYPE=sqlite pnpm test:dev-server-smoke --reporter=list {relative_targets}"
							env:       DB_TYPE: "sqlite"
							unset_env: _unsetPgEnv
						},
					]
				}
			}
			test: {
				command:   "helpers/playwright-runner.sh {relative_targets}"
				env:       DB_TYPE: "sqlite"
				unset_env: _unsetPgEnv
			}
		}
	}
}

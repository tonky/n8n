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
	let _depFilter = [if #pkg == "n8n-nodes-base" {"'" + #pkg + "...'"}, "'" + #pkg + "^...'"][0]
	let _extraDeps = strings.Join(["@n8n/eslint-config", "@n8n/oxlint-config", if #styles {"@n8n/stylelint-config"}], " ")
	command: "helpers/build-workspace-deps.sh --checked " + _depFilter + " " + _extraDeps + " && pnpm turbo run --only --env-mode=loose " + _tasks + " --filter=" + #pkg + " --output-logs=errors-only"
	env: {GOMEMLIMIT: "3072MiB", GOGC: "50"}
}

_typecheck: {
	#pkg:          string
	#declarations: bool | *false
	command: "helpers/build-workspace-deps.sh --checked '" + #pkg + "^...' && pnpm turbo run --only --env-mode=loose typecheck --filter=" + #pkg + " --output-logs=errors-only" + [
		if #declarations {" && RELEASE=true helpers/build-workspace-deps.sh --checked " + #pkg + " && test -f dist/index.d.ts"},
		"",
	][0]
}

_browserCheck: {direct: true, services: false, resources: {cpus: 4.0, memory_mb: 10240}}
_vitest:       "helpers/vitest-runner.sh {relative_targets}"

_chromiumBrowsers: schema.#Browsers & {
	engine:   "chromium"
	path:     "/tmp/.cache/ms-playwright"
	env:      "PLAYWRIGHT_BROWSERS_PATH"
	key:      ["packages/quality/testing/playwright/package.json", "pnpm-lock.yaml"]
	artifact: "tools/playwright-browsers-linux-amd64.tar.zst"
}

// A whole traced suite on a fresh map (the nightly) runs past the 600 s default step limit,
// which judges a shard with no recorded durations: frontend's 6 shards take ~1,200 s traced.
_wholeSuiteTimeout: "45m"

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
			"packages/@n8n/module-cli", "packages/@n8n/typescript-config",
		]
	}

	analysis: recorders: {"e2e-footprint.mjs": "1", "n8n-services": "1"}

	analysis: derived: [
		for _, p in _packages if p.built {
			outputs: [p.dir + "/dist/**", p.dir + "/.turbo/**"]
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
		// The editable install's setuptools metadata, written into the source tree by
		// `uv run` (LEARNINGS.md): PKG-INFO and requires.txt from pyproject.toml and the
		// README, SOURCES.txt from the files under src/.
		{
			outputs: ["packages/@n8n/task-runner-python/*.egg-info/**"]
			inputs:  ["packages/@n8n/task-runner-python/pyproject.toml", "packages/@n8n/task-runner-python/README.md"]
			layout:  ["packages/@n8n/task-runner-python/src/**"]
		},
	]

	caches: {
		vitest_transforms: {paths: ["node_modules/.vitest-cache"], key: ["pnpm-lock.yaml"], scope: "task", used_by: jobs: ["test", "migrate"]}
		node_build:        {paths: [".turbo"], key: ["package.json", "pnpm-lock.yaml"], scope: "task", refresh: "rolling"}
	}

	components: {
		root: {
			name: "root", title: "n8n Environment, Pipeline & pnpm Workspace", technology: "typescript", root: "."
			watch_paths: [
				"enve.cue", "enve.lock", "ENACT.md", ".enact/**", "cue.mod", "bin/**", ".github/workflows/**",
				".githooks/**", ".gitignore", ".gitattributes", ".editorconfig",
				"package.json", "pnpm-lock.yaml", "pnpm-workspace.yaml", "turbo.json",
				"tsconfig.json", "tsconfig.configs.json", "biome.jsonc", "vitest.workspace.ts",
				".prettierrc.js", ".prettierignore", "lefthook.yml", "knip.ts",
				".boundaries-baseline.json", ".code-health-baseline.json", "agent-harness.lock.json",
				"patches/**", "scripts/**", "helpers/vitest-runner.sh", "helpers/repair-node-modules.sh", "helpers/pnpm-store.sh",
				"helpers/build-workspace-deps.sh", "helpers/schema-docs-postgres.mjs", "helpers/trace/**",
			]
			depends_on:      []
			workspace_scope: include_dependencies: true
			jobs: lint: {
				name:     "Workspace Integrity, Boundaries, Formatting & Packaging"
				direct:   true
				services: false
				tasks: [
					{name: "Check workspace package integrity", command: "node scripts/check-workspace-private-deps.mjs"},
					{name: "Check module boundaries", command: "node scripts/check-boundaries.mjs"},
					{name: "Check formatting", command: "pnpm format:check"},
					{name: "Check packaging", command: "helpers/build-workspace-deps.sh --checked 'n8n-node-dev^...' && CI=true pnpm -r --reporter=silent pack --dry-run >/dev/null"},
				]
			}
		}

		for n, p in _packages {
			(n): {
				name:        n
				root:        p.dir
				watch_paths: *[p.dir + "/**", for f in p.reads {f}] | [...string]
				depends_on:  *["root", for d in p.deps {d}] | [...string]
				workspace_scope: {
					include_dependencies: true
					if len(p.reads) > 0 {include: [p.dir, for f in p.reads {f}]}
				}
				if p.shards > 0 {shards: *p.shards | int}
				if len(p.tests) > 0 {
					target_scope: _target_scope & {#dir: p.dir, #tests: p.tests, #ignore: p.exclude}
					recorder:     *"own_linux" | string
					recorded_by:  *["enact-node"] | [...string]
					jobs: test: {
						name:  *"Test" | string
						tasks: *[{name: "Run Tests", command: _vitest}] | [...schema.#Task]
					}
				}
				if len(p.exclude) > 0 {target_scope: exclude: p.exclude}
				if len(p.handoff) > 0 {target_scope: handoff: p.handoff}
				if p.lint {
					jobs: lint: {
						name:     "Lint"
						direct:   true
						services: false
						tasks:    [_lint & {#pkg: p.pkg, #styles: p.lint_styles, #format: p.format_check, name: "Run Linter"}]
					}
				}
				if p.typecheck {
					jobs: typecheck: {
						name:     "Typecheck"
						direct:   true
						services: false
						tasks:    [_typecheck & {#pkg: p.pkg, #declarations: p.declarations, name: "Typecheck"}]
					}
				}
			}
		}

		frontend: jobs: test: tasks: [{name: "Run Tests", command: _vitest, timeout: _wholeSuiteTimeout}]

		"@n8n/expression-runtime": jobs: test: tasks: [{name: "Run Tests", command: _vitest, env: N8N_TESTS_READ_OWN_BUILD: "1"}]

		"@n8n/efficiency": {
			browsers: _chromiumBrowsers
			jobs: {
				lint:      _browserCheck
				typecheck: _browserCheck
			}
		}

		"@n8n/node-cli": jobs: {
			lint:      resources: {cpus: 4.0, memory_mb: 6144}
			typecheck: resources: {cpus: 4.0, memory_mb: 6144}
			test: {worker: "standard", resource_forecast: {mode: "advisory"}}
		}

		"nodes-base": {
			let P = _packages["nodes-base"]
			let Services = {kafka: n8n.services.kafka, mysql: n8n.services.mysql}
			// Its services are the integration job's: the unit suite starts none.
			services: Services
			jobs: {
				test: services: false
				// Every `*.integration.test.ts`, under upstream's integration config (upstream runs
				// them by hand, test:integration:skip). Kafka's and MySQL's reach enve's broker and
				// server (N8N_TEST_KAFKA_BROKER, N8N_TEST_MYSQL_*: patches/0001), not testcontainers.
				integration: {
					recorder:     "own_linux"
					recorded_by:  ["enact-node"]
					target_scope: _target_scope & {#dir: P.dir, #tests: [P.dir + "/{credentials,nodes}/**/*.integration.test.ts"]}
					tasks: [{
						name:    "integration"
						command: "VITEST_RUNNER_ARGS='--config vitest.integration.config.ts --coverage.enabled=false' helpers/vitest-runner.sh {relative_targets}"
						env: ENACT_FOOTPRINT_SERVICES: strings.Join([for name, _ in Services {name}], " ")
					}]
				}
			}
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
			kind:            "service"
			domain:          "execution"
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
			title:           "n8n Database & Entities"
			kind:            "library"
			domain:          "backend"
			uses:            [{protocol: schema.#Protocol.Sql, target: "postgres", title: "Workflow & execution persistence"}]
			watch_paths:     [P.dir + "/**", "docs/generated/**", ".tbls.*.yml"]
			workspace_scope: include: [P.dir, "docs/generated", ".tbls.postgres.yml", ".tbls.sqlite.yml", "packages/cli/src/services/ownership-transfer/ownership-transfer.manifest.json"]
			services:        Services
			recorded_by:     ["enact-node", "n8n-services"]
			jobs: {
				build: {
					name: "Build @n8n/db", services: false
					// Preserve the previous cold producer allocation as a workload floor.
					resources: {cpus: 4.0, memory_mb: 8192}
					outputs: {
						paths: [
							P.dir + "/dist", P.dir + "/dist/index.js",
							P.dir + "/src/migrations/sqlite/index.ts",
							P.dir + "/src/migrations/postgresdb/index.ts",
						]
						key: [
							P.dir + "/**",
							for d in P.deps if _packages[d].built {_packages[d].dir + "/**"},
							"helpers/build-workspace-deps.sh", "helpers/pnpm-store.sh",
							"package.json", "pnpm-lock.yaml", "pnpm-workspace.yaml",
							"tsconfig.json", "turbo.json",
						]
					}
					tasks: [{command: "node scripts/generate-migration-index.mjs && helpers/build-workspace-deps.sh " + P.pkg}]
				}
				schema_check: {
					name:   "Schema Check"
					direct: true
					let _schemaFilter = [P.dir + "/src/migrations/**", P.dir + "/src/entities/**", P.dir + "/scripts/schema-docs.mjs", "docs/generated/sqlite-schema/**", "docs/generated/postgres-schema/**", ".tbls.sqlite.yml", ".tbls.postgres.yml"]
					tasks: [
						{
							name:    "Build @n8n/db for Schema Check"
							command: "node scripts/generate-migration-index.mjs && helpers/build-workspace-deps.sh " + P.pkg
							filter:  {include: _schemaFilter, on_empty: "skip"}
						},
						{
							name:      "Verify SQLite Schema Docs"
							command:   "node scripts/schema-docs.mjs diff --db=sqlite"
							unset_env: ["CI"]
							filter:    {include: [P.dir + "/src/migrations/**", P.dir + "/src/entities/**", P.dir + "/scripts/schema-docs.mjs", "docs/generated/sqlite-schema/**", ".tbls.sqlite.yml"], on_empty: "skip"}
						},
						{
							name:      "Verify Postgres Schema Docs"
							command:   "node --import $ENACT_RECORDERS_DIR/js/testcontainers-enve-shim.mjs scripts/schema-docs.mjs diff --db=postgres"
							unset_env: ["CI"]
							filter:    {include: [P.dir + "/src/migrations/**", P.dir + "/src/entities/**", P.dir + "/scripts/schema-docs.mjs", "docs/generated/postgres-schema/**", ".tbls.postgres.yml"], on_empty: "skip"}
						},
					]
				}
				test: tasks: [{
					name:    "Run Tests"
					command: "node scripts/generate-migration-index.mjs && " + _vitest
					env: ENACT_FOOTPRINT_SERVICES: strings.Join([for service in Services {service.name}], " ")
				}]
			}
		}

		cli: {
			let P = _packages.cli
			let Services = [n8n.services.postgres, n8n.services.redis]
			title:  "n8n CLI & Backend Service"
			kind:   "service"
			domain: "backend"
			uses: [
				{protocol: schema.#Protocol.Sql, target: "postgres", title: "Stores workflows, credentials & executions"},
				{protocol: schema.#Protocol.Redis, target: "redis", title: "Queue mode job coordination & cache"},
				{protocol: schema.#Protocol.Tcp, target: "@n8n/task-runner-python", title: "Dispatches Python code node tasks"},
			]
			watch_paths: [P.dir + "/**", "helpers/n8n-template-db.cjs"]
			services:    Services
			service:     n8n.services.cli
			resources:   {cpus: 2.0, memory_mb: 4096}
			recorded_by: ["enact-node", "n8n-services"]
			jobs: {
				lint:      _browserCheck
				typecheck: _browserCheck
				test: {
					fixture: {
						scope:   "shard"
						setup:   "helpers/vitest-runner.sh --setup-fixture {relative_targets}"
						release: "helpers/vitest-runner.sh --release-fixture"
					}
					tasks: [{
						name:    "Run Tests"
						command: _vitest
						timeout: _wholeSuiteTimeout
						env: {
							ENACT_FOOTPRINT_SERVICES: strings.Join([for service in Services {service.name}], " ")
							// The event bus's log writer runs cli's own build in a worker thread
							// (`dist/eventbus/.../message-event-bus-log-writer-worker.js` under NODE_ENV=test).
							N8N_TESTS_READ_OWN_BUILD: "1"
						}
					}]
				}
				migrate: {
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
		}

		playwright: {
			let P = _packages.playwright
			title:       "n8n End-to-End Playwright Suite"
			kind:        "verification"
			domain:      "verification"
			watch_paths: [P.dir + "/**", "helpers/playwright-runner.sh", "helpers/pw-spec-env.mjs", "helpers/n8n-ready.mjs"]
			browsers:    _chromiumBrowsers
			shards:      4
			recorder:    "own"
			target_scope: _target_scope & {
				#dir:    P.dir
				#tests:  [P.dir + "/tests/**/*.spec.ts", P.dir + "/**/*.test.{ts,mjs}"]
				#ignore: [P.dir + "/tests/dev-server-smoke/**/*.spec.ts"]
				exclude: [P.dir + "/tests/dev-server-smoke/**/*.spec.ts"]
				#runner: ["helpers/playwright-runner.sh", "helpers/pw-spec-env.mjs"]
				// Not run either: the `engine-v2:e2e` project (upstream's "E2E on engine v2", the
				// `@engine:*` specs of tests/e2e, which this suite runs on engine v1). It exists only
				// in container mode: n8n-containers starts Postgres, a main in remote engine mode and
				// an `n8n engine` container sharing its storage, and the parity fixture reads the
				// engine mode from that stack's config.
				not_run: [{
					tests:  [for d in ["cli-workflows", "evals", "infrastructure", "performance"] {P.dir + "/tests/" + d + "/**/*.spec.ts"}]
					reason: "Playwright projects other than e2e and dev-server-smoke: upstream runs them against containers (infrastructure, performance), workflow fixtures (cli-workflows) or an LLM (evals)"
				}, {
					tests:  [P.dir + "/tests/framework/harness-contract.test.ts"]
					reason: "drives Playwright in a subprocess under its own Vitest config (test:harness), which the runner's vitest.config.ts leaves out"
				}, {
					tests: [for s in [
						"auth/token-exchange", "settings/log-streaming/log-streaming", "workflow-reviews/review-round-trip",
						"type-availability-policies/credential-type-policy", "type-availability-policies/credential-type-policy-worker",
						"type-availability-policies/node-type-policy",
					] {P.dir + "/tests/e2e/" + s + ".spec.ts"}]
					reason: "@licensed specs whose module starts only with an enterprise license (upstream's N8N_LICENSE_CERT/N8N_LICENSE_ACTIVATION_KEY secrets; its fork PRs run --grep-invert=@licensed): enableFeature can't start it later"
				}, {
					tests:  [P.dir + "/tests/e2e/api/workflow-publication-service.spec.ts"]
					reason: "its `services` fixture reads n8nContainer.services, null outside container mode: a TypeError before the test's own sqlite skip (upstream, on x86 and ARM)"
				}]
			}
			resources: {cpus: 4.0, memory_mb: 10240}
			jobs: {
				build: {
					name: "Build Playwright workspace dependencies", services: false, resources: {cpus: 4.0, memory_mb: 8192}
					needs: ["@n8n/db:build"]
					outputs: {
						// Every package build the suite imports or serves, not only cli's and the
						// editor's: a shard restoring these runs on them as they are.
						paths: [
							for d in _e2eBuilds {d + "/dist"},
							"packages/cli/dist/commands/start.js", "packages/frontend/editor-ui/dist/index.html",
						]
						key: [
							for _, d in _packages if d.built {d.dir + "/**"},
							"helpers/build-workspace-deps.sh", "helpers/pnpm-store.sh",
							"package.json", "pnpm-lock.yaml", "pnpm-workspace.yaml",
							"tsconfig.json", "turbo.json",
						]
					}
					tasks: [{command: "helpers/build-workspace-deps.sh 'n8n-playwright^...'"}]
				}
				lint:      _browserCheck
				typecheck: _browserCheck
				dev_server_smoke: {
					name:     "Dev-Server Boot Smoke"
					needs:    ["build", "@n8n/db:build"]
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
					// `--trace=off`: the config's `trace: 'on'` writes and rereads trace resources
					// under test-results/ while a spec runs, which unsettles its footprint.
					tasks: [
						{
							name:      "Run dev-server smoke spec (non-default ports)"
							command:   "DB_TYPE=sqlite pnpm test:dev-server-smoke:alt-port --reporter=list --trace=off {relative_targets}"
							env:       DB_TYPE: "sqlite"
							unset_env: _unsetPgEnv
						},
						{
							name:      "Run dev-server smoke spec"
							command:   "DB_TYPE=sqlite pnpm test:dev-server-smoke --reporter=list --trace=off {relative_targets}"
							env:       DB_TYPE: "sqlite"
							unset_env: _unsetPgEnv
						},
					]
				}
				test: {
					name:  "Test"
					needs: ["build", "@n8n/db:build"]
					// Keep the owned recorder within the existing 13 GiB full carrier:
					// 11 GiB payload plus the pool's 2 GiB setup reserve.
					record_resources: {cpus: 4.0, memory_mb: 11264}
					tasks: [{
						name:      "Run Tests"
						command:   "helpers/playwright-runner.sh {relative_targets}"
						timeout:   _wholeSuiteTimeout
						env:       DB_TYPE: "sqlite"
						unset_env: _unsetPgEnv
					}]
				}
			}
		}
	}
}

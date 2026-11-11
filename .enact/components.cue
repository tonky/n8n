package n8n

import (
	"enact.dev/schema"
	"strings"
)

// One component per pnpm workspace package (packages.cue, generated from upstream's
// workspace by tools/gen_packages.py), plus hand-declared overrides for db, cli,
// playwright and @n8n/task-runner-python.

_lint: {
	#dir:    string
	#pkg:    string
	#styles: bool | *false
	#format: bool | *false
	command: "helpers/lint-runner.sh" + [if #styles {" --styles"}, ""][0] + [if #format {" --format"}, ""][0] + " " + #dir + " " + #pkg + " {relative_changed_files}"
	env: {GOMEMLIMIT: "3072MiB", GOGC: "50"}
}

_typecheck: {
	#dir:          string
	#pkg:          string
	#declarations: bool | *false
	command: "helpers/typecheck-runner.sh" + [if #declarations {" --declarations"}, ""][0] + " " + #dir + " " + #pkg
}

_vitest: "helpers/vitest-runner.sh {relative_targets}"

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
		{match: ["docs/generated/**", ".tbls.*.yml", "packages/**/{README,AGENTS,CHANGELOG,LICENSE}*.md"], action: "ignore"},
		if #dir != "packages/frontend/@n8n/i18n" {match: ["packages/frontend/@n8n/i18n/src/locales/*.json"], action: "ignore"},
		if len(#runner) > 0 {match: #runner, action: "full_component"},
		{match: ["packages/**/*.{ts,tsx,mts,cts,js,mjs,cjs,vue,md}", "packages/**/package.json"], engine: "reach"},
		{match: ["packages/**/{src,evaluations,test,__tests__,nodes,credentials,data,expectations,templates}/**/*.{json,jsonl,yml,yaml,mjml,handlebars}"], engine: "reach"},
	]
}

pipeline: schema.#Pipeline & {
	name:        "n8n-platform"
	description: "n8n Workflow Automation Platform (enact + enve accelerated)"

	workspace_scope: {
		ignore: [
			".actrc", ".agents/**", ".aikido", ".claude/**", ".claude-plugin/**", ".devcontainer/**", ".dockerignore",
			".env.*.example", ".git-blame-ignore-revs", ".jscpd.json", ".github/ISSUE_TEMPLATE/**",
			".github/actionlint.yml", ".github/actions/**", ".github/docker-compose.yml",
			".github/poutine-rules/**", ".github/scripts/**", ".github/test-metrics/**", ".github/upstream-workflows/**",
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

	let _dualTsc = {"base": true, "@n8n/ai-node-sdk": true, "@n8n/ai-utilities": true}
	let _nodePkg = {"nodes-base": true, "@n8n/n8n-nodes-langchain": true}
	let _noSrcDir = {
		"@n8n/code-health": true, "@n8n/eslint-config": true, "@n8n/eslint-plugin-community-nodes": true,
		"@n8n/json-schema-to-zod": true, "@n8n/oxlint-config": true, "@n8n/playwright-janitor": true,
		"@n8n/rules-engine": true, "@n8n/stylelint-config": true, "@n8n/test-impact": true, "@n8n/vitest-config": true,
	}
	let _cliExtraOutputs = [
		"packages/cli/dist/timezones.json",
		"packages/cli/dist/agent-library-bundle.js",
		"packages/cli/dist/user-management/email/templates/**",
		"packages/cli/dist/public-api/v1/openapi.yml",
		"packages/cli/dist/modules/agents/integrations/platforms/*/assets/**",
		"packages/cli/dist/eventbus/message-event-bus-writer/message-event-bus-log-writer-worker.*",
	]
	let _nodeMetaOutputs = ["/dist/known/**", "/dist/types/**", "/dist/methods/**", "/dist/node-definitions/**"]

	analysis: derived: [
		for n, p in _packages if p.built && n != "@n8n/expression-runtime" {
			let Bundles = [if n != "@n8n/mcp-apps" for b in p.bundles {b}]
			outputs: [p.dir + "/dist/**", p.dir + "/.turbo/**"]
			if n == "cli" {exclude_outputs: _cliExtraOutputs}
			if _nodePkg[n] != _|_ {exclude_outputs: [for g in _nodeMetaOutputs {p.dir + g}]}
			inputs: [p.dir + "/**", for b in Bundles {b + "/**"}]
			exclude: [
				for d in [p.dir, for b in Bundles {b}] for e in ["/dist/**", "/evaluations/**", "/**/*.test.ts", "/**/*.spec.ts", "/**/*.stories.*", "/**/__tests__/**", "/**/test/**", "/**/*.md"] {d + e},
				for db in ["sqlite", "postgresdb"] {"packages/@n8n/db/src/migrations/" + db + "/index.ts"},
				"packages/@n8n/expression-runtime/src/bridge/isolated-vm-bridge.ts",
				"packages/@n8n/expression-runtime/src/pool/**",
			]
			mapped: [for d in [p.dir, for b in Bundles {b}] {d + "/**"}]
			if !p.bundled && _noSrcDir[n] == _|_ {
				if _dualTsc[n] != _|_ {
					transpiled: [{from: p.dir + "/src", to: [p.dir + "/dist/cjs", p.dir + "/dist/esm"]}]
				}
				if _nodePkg[n] != _|_ {
					transpiled: [{from: p.dir, to: [p.dir + "/dist"]}]
				}
				if _dualTsc[n] == _|_ && _nodePkg[n] == _|_ {
					transpiled: [{from: p.dir + "/src", to: [p.dir + "/dist"]}]
				}
			}
		},
		for n in ["nodes-base", "@n8n/n8n-nodes-langchain"] {
			let P = _packages[n]
			outputs: [P.dir + "/dist/known/credentials.json", P.dir + "/dist/types/credentials.json"]
			inputs:  [P.dir + "/package.json", P.dir + "/credentials/**"]
			exclude: [for e in ["/**/*.test.ts", "/**/*.spec.ts", "/**/__tests__/**", "/**/test/**", "/**/*.md"] {P.dir + e}]
		},
		for n in ["nodes-base", "@n8n/n8n-nodes-langchain"] {
			let P = _packages[n]
			outputs: [P.dir + "/dist/known/nodes.json", P.dir + "/dist/types/nodes.json", P.dir + "/dist/methods/**", P.dir + "/dist/node-definitions/**"]
			inputs:  [P.dir + "/package.json", P.dir + "/nodes/**", P.dir + "/utils/**"]
			exclude: [for e in ["/**/methods/**", "/**/types.ts", "/**/*.test.ts", "/**/*.spec.ts", "/**/__tests__/**", "/**/test/**", "/**/*.md"] {P.dir + e}]
		},
		{
			outputs: ["packages/cli/dist/timezones.json"]
			inputs:  ["packages/cli/scripts/build.mjs", "packages/cli/package.json", "pnpm-lock.yaml"]
		},
		{
			outputs: ["packages/cli/dist/agent-library-bundle.js"]
			inputs:  ["packages/cli/scripts/bundle-agent-library.mjs", "packages/@n8n/agents/src/sdk/**"]
			exclude: ["packages/@n8n/agents/**/*.test.ts", "packages/@n8n/agents/**/__tests__/**"]
		},
		{
			outputs: ["packages/cli/dist/user-management/email/templates/**"]
			inputs:  ["packages/cli/scripts/build.mjs", "packages/cli/src/user-management/email/templates/**"]
		},
		{
			outputs: ["packages/cli/dist/public-api/v1/openapi.yml"]
			inputs:  ["packages/cli/scripts/build.mjs", "packages/cli/src/public-api/**"]
			exclude: ["packages/cli/src/public-api/**/*.test.ts", "packages/cli/src/public-api/**/__tests__/**"]
		},
		{
			outputs: ["packages/cli/dist/modules/agents/integrations/platforms/*/assets/**"]
			inputs:  ["packages/cli/scripts/build.mjs", "packages/cli/src/modules/agents/integrations/platforms/**"]
			exclude: ["packages/cli/src/modules/agents/integrations/platforms/**/*.test.ts", "packages/cli/src/modules/agents/integrations/platforms/**/__tests__/**"]
		},
		{
			outputs: ["packages/cli/dist/eventbus/message-event-bus-writer/message-event-bus-log-writer-worker.*"]
			inputs:  ["packages/cli/src/eventbus/**", "packages/cli/tsconfig.json", "packages/cli/tsconfig.build.json", "packages/cli/package.json"]
			exclude: ["packages/cli/src/eventbus/**/*.test.ts", "packages/cli/src/eventbus/**/__tests__/**"]
		},
		{
			let P = _packages["@n8n/expression-runtime"]
			outputs:         [P.dir + "/dist/**", P.dir + "/.turbo/**"]
			exclude_outputs: [P.dir + "/dist/bundle/**"]
			inputs:          [P.dir + "/**"]
			exclude:         [for e in ["/dist/**", "/**/*.test.ts", "/**/*.spec.ts", "/**/__tests__/**", "/**/test/**", "/**/*.md"] {P.dir + e}]
			mapped:          [P.dir + "/**"]
			transpiled:      [{from: P.dir + "/src", to: [P.dir + "/dist/cjs", P.dir + "/dist/esm"]}]
		},
		{
			let P = _packages["@n8n/expression-runtime"]
			outputs: [P.dir + "/dist/bundle/**"]
			inputs:  [P.dir + "/esbuild.config.js", P.dir + "/package.json", P.dir + "/src/{runtime,extensions,types}/**", P.dir + "/src/bridge/bridge-messages.ts", for b in P.bundles {b + "/**"}]
			exclude: [for d in [P.dir, for b in P.bundles {b}] for e in ["/dist/**", "/**/*.test.ts", "/**/*.spec.ts", "/**/__tests__/**", "/**/test/**", "/**/*.md"] {d + e}]
			mapped:  [P.dir + "/src/{runtime,extensions,types}/**", for b in P.bundles {b + "/**"}]
		},
		{outputs: ["packages/cli/test-exports-*/**"], inputs: ["packages/cli/test/integration/environments/source-control-export.service.test.ts"]},
		{
			outputs: ["packages/@n8n/workflow-sdk/test-fixtures/real-workflows/[0-9]*.json"]
			inputs:  ["packages/@n8n/workflow-sdk/test-fixtures/real-workflows/public_published_templates.zip", "packages/@n8n/workflow-sdk/test-fixtures/real-workflows/manifest.json"]
		},
		for db in ["sqlite", "postgresdb"] {
			outputs: [
				"packages/@n8n/db/src/migrations/" + db + "/index.ts",
				"packages/@n8n/db/dist/migrations/" + db + "/index.*",
				"packages/@n8n/db/dist/index.*",
			]
			inputs: ["packages/@n8n/db/scripts/generate-migration-index.mjs", "packages/@n8n/db/src/migrations/common/[0-9]*.ts", "packages/@n8n/db/src/migrations/" + db + "/[0-9]*.ts"]
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
		vitest_transforms: {paths: ["node_modules/.vitest-cache"], key: ["pnpm-lock.yaml"], scope: "task", used_by: {components: ["@n8n/node-cli"], jobs: ["test"]}}
		node_build:        {paths: [".turbo"], key: ["package.json", "pnpm-lock.yaml"], scope: "task", refresh: "rolling", used_by: jobs: ["build", "lint", "typecheck"]}
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
				"patches/**", "scripts/**", "helpers/vitest-runner.sh", "helpers/lint-runner.sh", "helpers/typecheck-runner.sh",
				"helpers/repair-node-modules.sh", "helpers/pnpm-store.sh",
				"helpers/build-workspace-deps.sh", "helpers/schema-docs-postgres.mjs", "helpers/trace/**",
			]
			depends_on:      []
			workspace_scope: include_dependencies: true
			jobs: lint: {
				name:      "Workspace Integrity, Boundaries, Formatting & Packaging"
				direct:    true
				services:  false
				resources: {cpus: 6.0, memory_mb: 8192}
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
					target_scope:     _target_scope & {#dir: p.dir, #tests: p.tests, #ignore: p.exclude}
					recorder:         *"own_linux" | string
					recorded_by:      *["enact-node"] | [...string]
					resources:        {cpus: *2.0 | number, memory_mb: *4096 | int}
					record_resources: {cpus: *2.0 | number, memory_mb: *4096 | int}
					jobs: test: {
						name:  *"Test" | string
						tasks: *[{name: "Run Tests", command: _vitest}] | [...schema.#Task]
					}
				}
				if len(p.exclude) > 0 {target_scope: exclude: p.exclude}
				if len(p.handoff) > 0 {target_scope: handoff: p.handoff}
				if p.lint {
					jobs: lint: {
						name:      "Lint"
						direct:    true
						services:  false
						resources: {cpus: *2.0 | number, memory_mb: *3072 | int}
						tasks:     [_lint & {#dir: p.dir, #pkg: p.pkg, #styles: p.lint_styles, #format: p.format_check, name: "Run Linter"}]
					}
				}
				if p.typecheck {
					jobs: typecheck: {
						name:      "Typecheck"
						direct:    true
						services:  false
						resources: {cpus: *2.0 | number, memory_mb: *3584 | int}
						tasks:     [_typecheck & {#dir: p.dir, #pkg: p.pkg, #declarations: p.declarations, name: "Typecheck"}]
					}
				}
			}
		}

		for n in ["cli", "nodes-base", "@n8n/n8n-nodes-langchain"] {
			(n): jobs: {
				lint:      resources: {cpus: 2.0, memory_mb: 4608}
				typecheck: resources: {cpus: 2.0, memory_mb: 6144}
			}
		}

		frontend: {
			resources:        {cpus: 4.0, memory_mb: 4096}
			record_resources: {cpus: 4.0, memory_mb: 6144}
			jobs: {
				lint:      resources: {cpus: 2.0, memory_mb: 5632}
				typecheck: resources: {cpus: 2.0, memory_mb: 7168}
				test: tasks: [{name: "Run Tests", command: _vitest, timeout: _wholeSuiteTimeout}]
			}
		}

		for n in ["@n8n/expression-runtime", "@n8n/n8n-nodes-langchain", "nodes-base"] {
			(n): jobs: test: tasks: [{name: "Run Tests", command: _vitest, env: N8N_TESTS_READ_OWN_BUILD: "1"}]
		}

		"@n8n/mcp-apps": {
			let P = _packages["@n8n/mcp-apps"]
			// Its server entrypoint (`@n8n/mcp-apps/server`, imported by cli) is pure backend TS;
			// its single-file UI preview imports primitives from @n8n/design-system source (staged
			// via workspace_scope.include) without making cli depend on @n8n/design-system.
			depends_on:      ["root", for d in P.deps if d != "@n8n/design-system" {d}]
			workspace_scope: include: [P.dir, for b in P.bundles {b}]
		}

		for n in ["@n8n/engine", "@n8n/node-engine-compatibility"] {
			(n): {
				let Services = [n8n.services.postgres]
				services:    Services
				recorded_by: ["enact-node"]
				jobs: test: tasks: [{
					name:    "Run Tests"
					command: _vitest
					env: ENACT_FOOTPRINT_SERVICES: strings.Join([for service in Services {service.name}], " ")
				}]
			}
		}

		"@n8n/efficiency": {
			browsers: _chromiumBrowsers
			jobs: {
				lint:      needs: ["playwright:build", "@n8n/db:build"]
				typecheck: needs: ["playwright:build", "@n8n/db:build"]
			}
		}

		"@n8n/node-cli": jobs: {
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
				rules: [
					{match: [Dir + "/**/*.py"], engine: "python"},
					{match: [Dir + "/{pyproject.toml,uv.lock,.python-version,README.md}"], engine: "reach"},
				]
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
					tasks: [{command: "helpers/build-workspace-deps.sh " + P.pkg}]
				}
				schema_check: {
					name:   "Schema Check"
					direct: true
					let _schemaFilter = [P.dir + "/src/migrations/**", P.dir + "/src/entities/**", P.dir + "/scripts/schema-docs.mjs", "docs/generated/sqlite-schema/**", "docs/generated/postgres-schema/**", ".tbls.sqlite.yml", ".tbls.postgres.yml"]
					tasks: [
						{
							name:    "Build @n8n/db for Schema Check"
							command: "helpers/build-workspace-deps.sh " + P.pkg
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
					command: _vitest
					env: ENACT_FOOTPRINT_SERVICES: strings.Join([for service in Services {service.name}], " ")
				}]
			}
		}

		cli: {
			let P = _packages.cli
			let Services = [n8n.services.postgres, n8n.services.redis]
			let _migrationScope = _target_scope & {#dir: P.dir, #tests: [P.dir + "/test/migration/**/*.test.ts"]}
			title:  "n8n CLI & Backend Service"
			kind:   "service"
			domain: "backend"
			uses: [
				{protocol: schema.#Protocol.Sql, target: "postgres", title: "Stores workflows, credentials & executions"},
				{protocol: schema.#Protocol.Redis, target: "redis", title: "Queue mode job coordination & cache"},
				{protocol: schema.#Protocol.Tcp, target: "@n8n/task-runner-python", title: "Dispatches Python code node tasks"},
			]
			watch_paths: [P.dir + "/**", "helpers/n8n-template-db.cjs"]
			services:         Services
			service:          n8n.services.cli
			shards:           8
			resources:        {cpus: 2.0, memory_mb: 4096}
			record_resources: {cpus: 4.0, memory_mb: 6144}
			recorded_by:      ["enact-node", "n8n-services"]
			target_scope: not_run: [{
				tests: [
					P.dir + "/test/integration/commands/credentials.cmd.test.ts",
					P.dir + "/test/integration/ldap/ldap.api.test.ts",
				]
				reason: "assume single-connection SQLite test:integration timing/locks: credentials.cmd.test.ts asserts 2 DbLockService.withLock calls while PostgreSQL DbConnection.migrate() adds a 3rd; ldap.api.test.ts:381 calls getPersonalProject(memberUser) without await so beforeEach UserRepository.delete() races on PostgreSQL's pool"
			}]
			jobs: {
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
				// Migrations run one file at a time in one process (`fileParallelism: false`):
				// PostgreSQL and SQLite are two jobs of 1 cpu each, sharded side by side. A
				// recording shard traces at most 2 workers (helpers/vitest-runner.sh).
				migrate: {
					recorder:         "own_linux"
					recorded_by:      ["enact-node", "n8n-services"]
					shards:           4
					resources:        {cpus: 1.0, memory_mb: 4096}
					record_resources: {cpus: 2.0, memory_mb: 6144}
					target_scope:     _migrationScope
					tasks: [
						{
							name:    "migrate"
							command: "VITEST_MIGRATION=1 helpers/vitest-runner.sh {relative_targets}"
							timeout: "20m"
							env: {
								ENACT_FOOTPRINT_SERVICES: strings.Join([for service in Services {service.name}], " ")
								N8N_LOG_LEVEL:            "silent"
								DB_TYPE:                  "postgresdb"
								DB_POSTGRESDB_SCHEMA:     "alt_schema"
								DB_TABLE_PREFIX:          "test_"
							}
						},
					]
				}
				// The same tests on SQLite: PostgreSQL's footprints are its evidence, and a file
				// none of them read runs it whole (code only SQLite's dialect may run).
				migrate_sqlite: {
					services:     false
					shards:       4
					resources:    {cpus: 1.0, memory_mb: 4096}
					target_scope: _migrationScope & {footprints_from: "cli:migrate"}
					tasks: [
						{
							name:    "migrate-sqlite"
							command: "VITEST_MIGRATION=1 helpers/vitest-runner.sh {relative_targets}"
							timeout: "20m"
							env: {
								N8N_LOG_LEVEL:       "silent"
								DB_TYPE:             "sqlite"
								DB_SQLITE_POOL_SIZE: "4"
							}
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
				#dir:   P.dir
				#tests: [P.dir + "/tests/**/*.spec.ts", P.dir + "/**/*.test.{ts,mjs}"]
				#ignore: [
					P.dir + "/tests/dev-server-smoke/**/*.spec.ts",
					for _, d in _packages if d.dir != P.dir {d.dir + "/**"},
				]
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
				lint:      needs: ["build", "@n8n/db:build"]
				typecheck: needs: ["build", "@n8n/db:build"]
				dev_server_smoke: {
					name:             "Dev-Server Boot Smoke"
					needs:            ["build", "@n8n/db:build"]
					recorder:         "trace"
					record_resources: {cpus: 4.0, memory_mb: 10240}
					target_scope: _target_scope & {
						let _ed = "packages/frontend/editor-ui"
						let _vc = "packages/frontend/@n8n/frontend-vite-config"
						#dir:   P.dir
						#tests: [P.dir + "/tests/dev-server-smoke/**/*.spec.ts"]
						#runner: [
							"helpers/playwright-runner.sh",
							"helpers/pw-spec-env.mjs",
							"helpers/n8n-ready.mjs",
							_vc + "/**",
							for f in ["index.html", "package.json", "postcss.config.cjs", "tailwind.config.js", "tsconfig.json", "vite.config.mts"] {_ed + "/" + f},
							for d in ["public", "vite"] {_ed + "/" + d + "/**"},
							_ed + "/src/*.{ts,scss}",
							_ed + "/src/app/**",
							for f in [
								"core", "workflows/canvas", "workflows/components", "workflows/composables",
								"workflows/workflowHistory", "ndv", "credentials", "collaboration", "shared",
							] {_ed + "/src/features/" + f + "/**"},
						]
						#ignore: [
							P.dir + "/tests/e2e/**/*.spec.ts",
							for d in ["cli-workflows", "evals", "infrastructure", "performance"] {P.dir + "/tests/" + d + "/**/*.spec.ts"},
							P.dir + "/**/*.test.{ts,mjs}",
							P.dir + "/expectations/**",
							for _, d in _packages if d.dir != P.dir && d.dir != _ed && d.dir != _vc {d.dir + "/**"},
							_ed + "/**/*.{test,spec,stories}.{ts,tsx,mts,cts,js,jsx,mjs,cjs}",
							_ed + "/**/{__tests__,__mocks__,test,tests}/**",
							_vc + "/**/*.{test,spec}.{ts,mts,js,mjs}",
							_vc + "/**/{__tests__,__mocks__,test,tests}/**",
							for f in ["*.md", "biome.jsonc", "eslint.config.mjs", "stylelint.config.mjs", "vitest.config.mts", ".oxlintrc.json"] {_ed + "/" + f},
							for d in ["data", "scripts"] {_ed + "/" + d + "/**"},
							_ed + "/src/experiments/**",
							for f in [
								"agents", "ai", "execution", "integrations", "resolvers", "roles", "settings",
								"setupPanel", "workflow-reviews", "workflows/readyToRun", "workflows/templates", "workflows/workflowDiff",
							] {_ed + "/src/features/" + f + "/**"},
						]
					}
					// `--trace=off`: the config's `trace: 'on'` writes and rereads trace resources
					// under test-results/ while a spec runs, which unsettles its footprint.
					tasks: [
						{
							name:      "Run dev-server smoke spec (non-default ports)"
							command:   "helpers/playwright-runner.sh --ensure-browsers && DB_TYPE=sqlite pnpm test:dev-server-smoke:alt-port --reporter=list --trace=off {relative_targets}"
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
					// Keep the owned recorder within the 12 GiB carrier (10 GiB payload + 2 GiB reserve).
					record_resources: {cpus: 4.0, memory_mb: 10240}
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

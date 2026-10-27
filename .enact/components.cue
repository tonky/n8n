package n8n

import "enact.dev/schema"

// One component per pnpm workspace package (packages.cue, generated from upstream's
// workspace by tools/gen_packages.py), its edges the package's workspace dependencies:
// a change to a package runs its own jobs and its dependents'. db, cli and playwright are
// declared by hand below (services, jobs of their own); the others come from their entries.

// Every package's lint: the package's own `lint` script, through turbo, after the workspace
// packages it reads are built (turbo.json: `^build` and the lint configs) one build at a
// time (build-workspace-deps.sh --checked: the check stage's jobs run side by side). A `lint`
// job runs only for the packages a change touches: a dependency's change reaches it through
// `typecheck` and `test`.
_lint: {
	#pkg: string
	command: "helpers/build-workspace-deps.sh --checked '" + #pkg + "^...' @n8n/eslint-config @n8n/oxlint-config && pnpm turbo run lint --filter=" + #pkg + " --output-logs=errors-only"
}

// Its `typecheck` script after its dependencies' builds (turbo.json: `^build`, built as
// lint's are), whenever the package or one of its dependencies changed.
_typecheck: {
	#pkg: string
	command: "helpers/build-workspace-deps.sh --checked '" + #pkg + "^...' && pnpm turbo run typecheck --filter=" + #pkg + " --output-logs=errors-only"
}

// Its vitest suite, the selected test files (vitest-runner.sh: unit tests on SQLite, cli's
// integration tests on PostgreSQL).
_vitest: "helpers/vitest-runner.sh {relative_targets}"

// Test selection in a package: its traced test files (the reach map), else the TypeScript
// import graph of its changed files. The tests it leaves out (`#ignore`: another suite's, or
// none's) reach none of its own: a change to one selects nothing here, where the import
// graph would find no test and run the suite whole (`fallback`).
_target_scope: {
	#dir: string
	#tests: [...string]
	#ignore: [...string] | *[]
	fallback: *"all" | "none"
	tests:    #tests
	rules: [
		if len(#ignore) > 0 {
			{match: #ignore, action: "ignore"}
		},
		{
			match: [#dir + "/**/*.{ts,tsx,mts,cts,js,mjs,cjs,vue}"]
			engine: "typescript"
		},
	]
}

pipeline: schema.#Pipeline & {
	name:        "n8n-platform"
	description: "n8n Workflow Automation Platform (enact + enve accelerated)"

	workspace_scope: {
		// Nothing the pipeline runs reads these: editor, agent and devcontainer settings,
		// docs and assets, docker images, and upstream's own CI (its workflows are replaced
		// by .github/workflows/enact-ci.yml; their actions and scripts run nowhere).
		ignore: [
			".actrc",
			".agents/**",
			".aikido",
			".claude/**",
			".devcontainer/**",
			".dockerignore",
			".env.*.example",
			".git-blame-ignore-revs",
			// Upstream's duplication scan (jscpd), which no job runs.
			".jscpd.json",
			".github/ISSUE_TEMPLATE/**",
			".github/actionlint.yml",
			".github/actions/**",
			".github/docker-compose.yml",
			".github/poutine-rules/**",
			".github/scripts/**",
			".github/test-metrics/**",
			".npmignore",
			".opencode",
			".poutine.yml",
			".vscode/**",
			"OWNERS",
			"assets/**",
			"codecov.yml",
			"cubic.yaml",
			"docker/**",
			// An empty directory's placeholder.
			"packages/extensions/.gitkeep",
			"security/**",
			// Codespaces tooling, as .devcontainer (it imports its plugins).
			"scripts/cloud-session*.mjs",
		]
		// What every job's checkout holds: the environment, the pipeline and the
		// workspace's manifests (pnpm installs from them). The packages come from the
		// components' cones.
		include: [
			"enve.cue",
			"enve.lock",
			".enact",
			"cue.mod",
			"bin",
			"helpers",
			"patches",
			"scripts",
			"package.json",
			"pnpm-lock.yaml",
			"pnpm-workspace.yaml",
			"turbo.json",
			"tsconfig.json",
			"tsconfig.configs.json",
			"biome.jsonc",
			"vitest.workspace.ts",
			".prettierrc.js",
			".prettierignore",
			// The tsconfig every package's and the root's extends.
			"packages/@n8n/typescript-config",
		]
	}

	// The e2e specs' recorder (helpers/trace/e2e-footprint.mjs, `"recorder"` in its maps): a
	// footprint made at another version is recorded again.
	analysis: recorders: "e2e-footprint.mjs": "1"

	// The tests import the workspace packages they depend on from their builds (`dist/`,
	// git-ignored, never in a diff): a change to a package's sources reaches every test that
	// read its build. Per package, not per file (a test reading any of db's `dist` is reached
	// by any change to db). Rules don't chain: a bundled build (vite, tsdown...) lists the
	// sources of the packages it may inline too. The packages' tests aren't built.
	analysis: derived: [for _, p in _packages if p.built {
		outputs: [p.dir + "/dist/**"]
		inputs: [p.dir + "/**", for b in p.bundles {b + "/**"}]
		exclude: [for d in [p.dir, for b in p.bundles {b}] for e in [
			"/dist/**", "/**/*.test.ts", "/**/*.spec.ts", "/**/__tests__/**", "/**/test/**", "/**/*.md",
		] {d + e}]
	},
		// cli's source-control export test writes `test-exports-<uuid>` into the package and
		// leaves it behind when it fails: the test's output, not a source, so a host that ran
		// it lists `packages/cli` as one that didn't.
		{
			outputs: ["packages/cli/test-exports-*/**"]
			inputs: ["packages/cli/test/integration/environments/source-control-export.service.test.ts"]
		},
		// workflow-sdk's tests extract the real workflows they read (`<id>.json`,
		// git-ignored) from the committed zip on first use (src/__tests__/fixtures-zip.ts): the
		// zip and its manifest stand for them, so a host that hasn't extracted them yet
		// digests as one that has.
		{
			outputs: ["packages/@n8n/workflow-sdk/test-fixtures/real-workflows/[0-9]*.json"]
			inputs: [
				"packages/@n8n/workflow-sdk/test-fixtures/real-workflows/public_published_templates.zip",
				"packages/@n8n/workflow-sdk/test-fixtures/real-workflows/manifest.json",
			]
		}]

	caches: {
		// vitest's transforms (vitest-runner.sh's `--fsModuleCache`), keyed by each module's
		// content: an older cache only misses, it never serves a stale module.
		vitest_transforms: {
			paths: ["node_modules/.vitest-cache"]
			key: ["pnpm-lock.yaml"]
			scope: "task"
		}
		// turbo's cache, which replays a package's build, lint or typecheck only when its
		// inputs hash the same; each CI task keeps its own entry since tasks build different
		// packages. Not the `dist` outputs: keyed on the lockfile they restored stale builds
		// (STALE_BUILD_OUTPUT_CACHE); turbo restores the outputs of the hashes that match
		// (helpers/build-workspace-deps.sh).
		node_build: {
			paths: [".turbo"]
			key: ["package.json", "pnpm-lock.yaml"]
			scope: "task"
		}
	}

	components: {
		// What every component runs with: the environment, the pipeline, CI, and the pnpm
		// workspace (one ecosystem: its manifests, lockfile and shared helpers are here, no
		// `js-root`). Every package depends on it.
		root: {
			name:  "root"
			title: "n8n Environment, Pipeline & pnpm Workspace"
			// The repository's one ecosystem: every package's install follows it.
			technology: "typescript"
			root:       "."
			watch_paths: [
				"enve.cue",
				"enve.lock",
				".enact/**",
				"cue.mod",
				// The committed enact and enve builds CI installs.
				"bin/**",
				".github/workflows/**",
				".githooks/**",
				".gitignore",
				".gitattributes",
				".editorconfig",
				"package.json",
				"pnpm-lock.yaml",
				"pnpm-workspace.yaml",
				"turbo.json",
				"tsconfig.json",
				"tsconfig.configs.json",
				"biome.jsonc",
				"vitest.workspace.ts",
				".prettierrc.js",
				".prettierignore",
				"lefthook.yml",
				"knip.ts",
				".boundaries-baseline.json",
				".code-health-baseline.json",
				"agent-harness.lock.json",
				// The pnpm patches the install applies.
				"patches/**",
				// Workspace scripts: install hooks (prepare, block-npm-install), the CI
				// integrity check, and the scripts packages run (os-normalize, lint-parity).
				"scripts/**",
				// Shared runner and trace helpers every package's jobs run.
				"helpers/vitest-runner.sh",
				// The store pin every runner sources (pnpm-store.sh).
				"helpers/pnpm-store.sh",
				// Every workspace build the jobs, the cli service and Playwright run.
				"helpers/build-workspace-deps.sh",
				"helpers/trace/**",
			]
			depends_on: []
			workspace_scope: include_dependencies: true
		}

		for n, p in _packages if !p.custom {
			(n): {
				name: n
				root: p.dir
				watch_paths: [p.dir + "/**", for f in p.reads {f}]
				depends_on: ["root", for d in p.deps {d}]
				workspace_scope: {
					include_dependencies: true
					// A component's own include replaces its root in its cone: both are named.
					if len(p.reads) > 0 {
						include: [p.dir, for f in p.reads {f}]
					}
				}
				if p.shards > 0 {
					shards: p.shards
				}
				if len(p.tests) > 0 {
					target_scope: _target_scope & {#dir: p.dir, #tests: p.tests, #ignore: p.exclude}
					test: _vitest
					// vitest-runner.sh records, with the functions each file ran (helpers/trace/footprints.sh, Linux).
					recorder: "own_linux"
					recorded_by: ["enact-node"]
				}
				// Tests its vitest config leaves out, which no suite runs (packages.cue's
				// `exclude`): never selected, as vitest would skip them.
				if len(p.exclude) > 0 {
					target_scope: exclude: p.exclude
				}
				// Tests reading what a dependent builds (packages.cue's `handoff`): they run
				// in its test job.
				if len(p.handoff) > 0 {
					target_scope: handoff: p.handoff
				}
				if p.lint {
					lint: _lint & {#pkg: p.pkg}
				}
				if p.typecheck {
					typecheck: _typecheck & {#pkg: p.pkg}
				}
			}
		}

		// nodes-base's `*.integration.test.ts`, which its vitest config leaves out (packages.cue's
		// `exclude`) and upstream runs by hand (`test:integration:skip`, its integration
		// config). The credentials' run against a local HTTP server: their own job, under that
		// config, after the builds of what they import (turbo.json: `^build`). Kafka's and
		// MySQL's start their brokers with testcontainers (n8n-containers), which needs a
		// container runtime: no suite runs them.
		"nodes-base": {
			let P = _packages["nodes-base"]
			let NotRun = [
				P.dir + "/nodes/Kafka/test/v2/kafka.integration.test.ts",
				P.dir + "/nodes/MySql/test/v2/mysql.integration.test.ts",
			]
			jobs: integration: {
				recorder: "own_linux"
				recorded_by: ["enact-node"]
				target_scope: _target_scope & {
					#dir: P.dir
					#tests: [P.dir + "/credentials/**/*.integration.test.ts"]
					#ignore: NotRun
				}
				tasks: [{
					name:    "integration"
					command: "VITEST_RUNNER_ARGS='--config vitest.integration.config.ts --dir credentials --coverage.enabled=false' helpers/vitest-runner.sh {relative_targets}"
				}]
			}
			target_scope: not_run: [{
				tests:  NotRun
				reason: "testcontainers (n8n-containers) starts their Kafka and MySQL: no container runtime under enve"
			}]
		}

		// agents' integration tests run against real model providers and vector stores (API
		// keys in `.env`); upstream runs them by hand (`test:integration`), its unit config
		// leaves them out.
		"@n8n/agents": target_scope: not_run: [{
			tests: [_packages["@n8n/agents"].dir + "/src/__tests__/integration/**"]
			reason: "real model providers and vector stores (API keys): upstream runs them by hand (test:integration)"
		}]

		// Known failures at the pin (GUIDELINES "Known upstream failures are tagged out"),
		// left out until it moves; plain runs fail them too.
		"@n8n/scan-community-package": target_scope: not_run: [{
			tests: [_packages["@n8n/scan-community-package"].dir + "/test/provenance.test.mjs"]
			reason: "a node:test file the package's vitest picks up: \"No test suite found\""
		}]
		"@n8n/workflow-sdk": target_scope: not_run: [{
			tests: [_packages["@n8n/workflow-sdk"].dir + "/src/codegen/codegen-roundtrip.test.ts"]
			reason: "57 real-workflow roundtrips fail against the manifest's expected warnings once the fixtures are extracted (a fresh checkout loads none at parse time and runs one test)"
		}]

		// The Python task runner (uv, pytest, ruff): no job yet, the environment has no
		// Python toolchain. Its manifests (pyproject.toml, uv.lock) are its own, so no
		// ecosystem root: nothing else installs from them.
		task_runner_python: {
			name:  "@n8n/task-runner-python"
			title: "n8n Python Task Runner"
			root:  "packages/@n8n/task-runner-python"
			watch_paths: ["packages/@n8n/task-runner-python/**"]
			depends_on: ["root"]
		}

		// The data layer: entities, repositories and migrations. Its `*.postgres.test.ts`
		// run against PostgreSQL; the migration index is generated before every run, as
		// the package's own scripts do (`gen:migration-index`). Its schema check diffs the
		// schema its migrations build against the committed docs (tbls, from enve).
		"@n8n/db": {
			let P = _packages["@n8n/db"]
			name:  "@n8n/db"
			title: "n8n Database & Entities"
			root:  P.dir
			watch_paths: [
				P.dir + "/**",
				// The schema docs, their tbls configs and the PostgreSQL shim (schema_check).
				"docs/generated/**",
				".tbls.*.yml",
				"helpers/schema-docs-postgres.mjs",
			]
			depends_on: ["root", for d in P.deps {d}]
			workspace_scope: {
				include_dependencies: true
				// Read by db's lint config (eslint-plugin rules on the transfer manifest).
				// A component's own include replaces its root in its cone: both are named.
				include: [
					P.dir,
					"docs/generated",
					".tbls.postgres.yml",
					".tbls.sqlite.yml",
					"packages/cli/src/services/ownership-transfer/ownership-transfer.manifest.json",
				]
			}
			services: [n8n.services.postgres]
			shards:       P.shards
			target_scope: _target_scope & {#dir: P.dir, #tests: P.tests}
			lint:         _lint & {#pkg: P.pkg}
			typecheck:    _typecheck & {#pkg: P.pkg}
			// Diffs both the SQLite and PostgreSQL schemas built by db's migrations against
			// the committed docs (`schema:check:sqlite`, `schema:check:postgres`). Upstream's
			// script runs tbls in docker when CI is set and starts a testcontainer for
			// PostgreSQL: with CI unset and helpers/schema-docs-postgres.mjs loaded, it runs
			// enve's tbls and creates a throwaway database on enve's PostgreSQL service.
			jobs: schema_check: {
				name: "Schema Check"
				tasks: [{
					name:    "Verify SQLite Schema Docs"
					command: "node scripts/generate-migration-index.mjs && helpers/build-workspace-deps.sh " + P.pkg + " && node scripts/schema-docs.mjs diff --db=sqlite"
					unset_env: ["CI"]
					filter: {
						include: [
							P.dir + "/src/migrations/**",
							P.dir + "/src/entities/**",
							P.dir + "/scripts/schema-docs.mjs",
							"docs/generated/sqlite-schema/**",
							".tbls.sqlite.yml",
						]
						on_empty: "skip"
					}
				}, {
					name:    "Verify Postgres Schema Docs"
					command: "node scripts/generate-migration-index.mjs && helpers/build-workspace-deps.sh " + P.pkg + " && node --import helpers/schema-docs-postgres.mjs scripts/schema-docs.mjs diff --db=postgres"
					unset_env: ["CI"]
					filter: {
						include: [
							P.dir + "/src/migrations/**",
							P.dir + "/src/entities/**",
							P.dir + "/scripts/schema-docs.mjs",
							"helpers/schema-docs-postgres.mjs",
							"docs/generated/postgres-schema/**",
							".tbls.postgres.yml",
						]
						on_empty: "skip"
					}
				}]
			}
			test:         "node scripts/generate-migration-index.mjs && " + _vitest
			recorder:     "own_linux"
			recorded_by: ["enact-node"]
		}

		// The backend: its unit tests on SQLite, its integration tests on PostgreSQL and
		// Redis (vitest-runner.sh), its migration tests in `migrate`.
		cli: {
			let P = _packages.cli
			name:  "cli"
			title: "n8n CLI & Backend Service"
			root:  P.dir
			watch_paths: [
				P.dir + "/**",
				// Builds the integration tests' template database.
				"helpers/n8n-template-db.cjs",
			]
			depends_on: ["root", for d in P.deps {d}]
			workspace_scope: include_dependencies: true
			services: [n8n.services.postgres, n8n.services.redis]
			service:      n8n.services.cli
			shards:       P.shards
			target_scope: _target_scope & {#dir: P.dir, #tests: P.tests}
			lint:         _lint & {#pkg: P.pkg}
			typecheck:    _typecheck & {#pkg: P.pkg}
			test:         _vitest
			recorder:     "own_linux"
			recorded_by: ["enact-node"]
			jobs: migrate: {
				// Migration tests share one database and roll back: one process, in order
				// (vitest.config.migration.ts), on PostgreSQL and on SQLite (upstream's
				// `test:postgres:migrations` and `test:sqlite:migrations`). Their migrations
				// are db's, so they are selected like tests: a change to db or cli runs the
				// tests it reaches.
				recorder: "own_linux"
				recorded_by: ["enact-node"]
				target_scope: _target_scope & {
					#dir: P.dir
					#tests: [P.dir + "/test/migration/**/*.test.ts"]
				}
				tasks: [{
					name:    "migrate"
					command: "VITEST_MIGRATION=1 helpers/vitest-runner.sh {relative_targets}"
					env: {
						N8N_LOG_LEVEL:        "silent"
						DB_TYPE:              "postgresdb"
						DB_POSTGRESDB_SCHEMA: "alt_schema"
						DB_TABLE_PREFIX:      "test_"
					}
				}, {
					name: "migrate-sqlite"
					// enve.cue sets DB_TYPE=postgresdb in the profile environment, which enve
					// applies on top of task.env, so set DB_TYPE=sqlite in the shell too.
					command: "DB_TYPE=sqlite DB_SQLITE_POOL_SIZE=4 VITEST_MIGRATION=1 helpers/vitest-runner.sh {relative_targets}"
					env: {
						N8N_LOG_LEVEL:       "silent"
						DB_SQLITE_POOL_SIZE: "4"
						DB_TYPE:             "sqlite"
					}
					unset_env: [
						"PGHOST",
						"PGPORT",
						"PGDATABASE",
						"PGUSER",
						"PGPASSWORD",
						"DB_POSTGRESDB_HOST",
						"DB_POSTGRESDB_PORT",
						"DB_POSTGRESDB_DATABASE",
						"DB_POSTGRESDB_USER",
						"DB_POSTGRESDB_PASSWORD",
					]
				}]
			}
		}

		// The end-to-end suite and its tooling: its own vitest tests (the fixtures and
		// helpers), and Playwright specs against an isolated n8n each
		// (scripts/run-local-isolated.mjs: a throwaway SQLite database per run).
		playwright: {
			let P = _packages.playwright
			name:  "playwright"
			title: "n8n End-to-End Playwright Suite"
			root:  P.dir
			watch_paths: [
				P.dir + "/**",
				"helpers/playwright-runner.sh",
				"helpers/pw-spec-env.mjs",
				"helpers/n8n-ready.mjs",
			]
			depends_on: ["root", "frontend", for d in P.deps {d}]
			workspace_scope: include_dependencies: true
			browsers: {
				engine: "chromium"
				path:   "/tmp/.cache/ms-playwright"
				env:    "PLAYWRIGHT_BROWSERS_PATH"
				key: [P.dir + "/package.json", "pnpm-lock.yaml"]
				// A miss hydrates from this archive in the remote cache bucket.
				artifact: "tools/playwright-browsers-linux-amd64.tar.zst"
			}
			shards: 4
			// Each recorded spec runs alone against an n8n of its own; its footprint is what its
			// Node.js processes read and the editor's outputs its browser fetched, mapped to their
			// sources (helpers/trace/e2e-footprints.sh). The package's vitest tests record
			// nothing yet: untraced, they run on every change the suite answers for.
			recorder: "own"
			target_scope: _target_scope & {
				#dir: P.dir
				#tests: [P.dir + "/tests/**/*.spec.ts", P.dir + "/**/*.test.{ts,mjs}"]
				// run-local-isolated.mjs runs the e2e project (tests/e2e); the runner fails
				// on the other projects' specs.
				not_run: [{
					tests: [for d in ["cli-workflows", "dev-server-smoke", "evals", "infrastructure", "performance"] {P.dir + "/tests/" + d + "/**/*.spec.ts"}]
					reason: "Playwright projects other than e2e: upstream runs them against containers (infrastructure, performance), a dev server (dev-server-smoke), workflow fixtures (cli-workflows) or an LLM (evals)"
				}]
			}
			resources: {
				cpus:      4.0
				memory_mb: 10240
			}
			lint:      _lint & {#pkg: P.pkg}
			typecheck: _typecheck & {#pkg: P.pkg}
			test: {
				command: "helpers/playwright-runner.sh {relative_targets}"
				// Each spec runs against its own throwaway SQLite database, so the
				// injected Postgres connection must not reach it.
				env: DB_TYPE: "sqlite"
				unset_env: [
					"PGHOST",
					"PGPORT",
					"PGDATABASE",
					"PGUSER",
					"PGPASSWORD",
					"DB_POSTGRESDB_HOST",
					"DB_POSTGRESDB_PORT",
					"DB_POSTGRESDB_DATABASE",
					"DB_POSTGRESDB_USER",
					"DB_POSTGRESDB_PASSWORD",
				]
			}
		}
	}
}

package enve

import (
	"github.com/tonky/enve/schema/v1:schema"
	"github.com/tonky/enve/pkgs:pkgs"
)

// package.json's `packageManager` pnpm, exactly (nixpkgs has 12.9): its native build
// (@pnpm/exe.*), which npm's `pnpm` package downloads on first run. A pnpm at another
// version switches itself to packageManager's (F-js-pnpm-ci-install); tests/conformance.rs
// checks the version against upstream's.
let pnpm = schema.#ArchiveBuildSpec & {
	pname:   "pnpm"
	version: "12.4.2"
	src: {
		"x86_64-linux":   "https://registry.npmjs.org/@pnpm/exe.linux-x64/-/exe.linux-x64-12.4.2.tgz"
		"aarch64-linux":  "https://registry.npmjs.org/@pnpm/exe.linux-arm64/-/exe.linux-arm64-12.4.2.tgz"
		"x86_64-darwin":  "https://registry.npmjs.org/@pnpm/exe.darwin-x64/-/exe.darwin-x64-12.4.2.tgz"
		"aarch64-darwin": "https://registry.npmjs.org/@pnpm/exe.darwin-arm64/-/exe.darwin-arm64-12.4.2.tgz"
	}
	sha256: {
		"x86_64-linux":   "545b89d5c6026ac33d4c28bd3c6cc38cc050d571b35a4e69f13aad4a441af142"
		"aarch64-linux":  "c3bb8caba00f308733b0876d245e1e1f3ad656e6605f4f85dd861457267ae9f2"
		"x86_64-darwin":  "135624819b30eecad9265a45ae08de4947ee259378d81971df721e72814454a6"
		"aarch64-darwin": "74e32d56a464eca1f2b3dbfc37adb6c017eb6449c455b87be98e7fa620d315af"
	}
	installPhase: "mkdir -p \"$out/bin\" && cp pnpm \"$out/bin/\" && chmod +x \"$out/bin/pnpm\""
}

profiles: dev: schema.#Profile & {
	name: "n8n-platform-dev"
	tools: [
		pnpm,
		pkgs.nodejs & {version: "24"},
		pkgs.postgresql,
		pkgs.redis,
		{pname: "tbls"},
		// What the helpers and probes run besides, resolved inside `enve run` (else the host's,
		// macOS's bash 3.2 has no `mapfile`): the cli readiness probe's `curl`,
		// playwright-runner.sh's `rg`, vitest-runner.sh's `nproc`/`realpath`, and
		// helpers/trace/generate-reach-map.sh's `python3`, and vitest-runner.sh's install lock
		// `flock`, which the kernel releases when a killed job dies (macOS has none).
		{pname: "curl"},
		{pname: "ripgrep"},
		{pname: "bash"},
		{pname: "coreutils"},
		{pname: "python3"},
		{pname: "flock"},
		// Playwright's headless shell and ffmpeg (for `video: 'on'`) from the store
		// (PLAYWRIGHT_BROWSERS_PATH) at the revision `@playwright/test` 1.62.1 expects.
		pkgs.#PlaywrightBrowsers & {version: "1.62.1", features: ["chromium-headless-shell", "ffmpeg"]},
	]
	services: {
		// Dedicated default ports (5438/6386 instead of 5432/6379) so `enve up` does not
		// collide with or adopt a system PostgreSQL or Redis already listening on standard ports.
		// They are the default instance's (`enve up` by hand): enact runs each run's services in
		// an instance of its own, on free ports, so commands, hooks and values read `$PORT` /
		// `${ENVE_SERVICE_<NAME>_PORT}`.
		postgres: {
			name:    "postgres"
			port:    5438
			command: "postgres -D \"$DATA_DIR\" -k \"$SOCKET_DIR\" -p $PORT -c shared_buffers=32MB -c work_mem=4MB -c max_connections=100 -c max_locks_per_transaction=256 -c fsync=off -c synchronous_commit=off"
			environment: {
				TZ:   "UTC"
				PGTZ: "UTC"
			}
			lifecycle: {
				postStart: "createdb -h 127.0.0.1 -p $PORT -U postgres n8n 2>/dev/null || true; psql -h 127.0.0.1 -p $PORT -U postgres -c \"ALTER DATABASE n8n SET timezone TO 'UTC';\" -c \"ALTER ROLE postgres SET timezone TO 'UTC';\" || true"
			}
		}
		redis: {
			name: "redis"
			port: 6386
		}
		cli: {
			name:    "cli"
			command: "sh -c 'mkdir -p node_modules/@n8n && for p in packages/@n8n/*; do [ -d \"$p\" ] && [ ! -e \"node_modules/@n8n/$(basename \"$p\")\" ] && ln -sfn \"$PWD/$p\" \"node_modules/@n8n/$(basename \"$p\")\"; done; helpers/build-workspace-deps.sh n8n... && exec node packages/cli/bin/n8n start'"
			port:    5678
			// The task runners' broker: a slot of its own, or a second instance's cli exits on
			// "Task Broker's port 5679 is already in use".
			ports: {broker: 5679}
			dependsOn: [{service: "postgres"}, {service: "redis"}]
			environment: {
				N8N_PORT:                          "${ENVE_SERVICE_CLI_PORT}"
				N8N_RUNNERS_BROKER_PORT:           "$PORT_BROKER"
				N8N_HOST:                          "127.0.0.1"
				N8N_DIAGNOSTICS_ENABLED:           "false"
				N8N_VERSION_NOTIFICATIONS_ENABLED: "false"
				N8N_ENCRYPTION_KEY:                "e2e-test-encryption-key-n8n"
				// n8n's `.n8n` (config, encryption key, logs) in the service's own data dir:
				// per checkout and instance, emptied at each start (a fixed /tmp dir is every
				// instance's on the host).
				N8N_USER_FOLDER:                   "$DATA_DIR"
				E2E_TESTS:                         "true"
			}
			readinessProbe: {
				command: "curl -s -f --connect-timeout 1 --max-time 3 http://127.0.0.1:$PORT/healthz || exit 1"
				port:    5678
				timeout: "90s"
			}
		}
	}
	environment: {
		TZ:                              "UTC"
		PGTZ:                            "UTC"
		DB_TYPE:                         "postgresdb"
		DB_POSTGRESDB_HOST:              "127.0.0.1"
		DB_POSTGRESDB_PORT:              "${ENVE_SERVICE_POSTGRES_PORT}"
		DB_POSTGRESDB_DATABASE:          "n8n"
		DB_POSTGRESDB_USER:              "postgres"
		DB_POSTGRESDB_PASSWORD:          ""
		PGUSER:                          "postgres"
		PGDATABASE:                      "n8n"
		QUEUE_BULL_REDIS_HOST:           "127.0.0.1"
		QUEUE_BULL_REDIS_PORT:           "${ENVE_SERVICE_REDIS_PORT}"
		// What upstream's testcontainers global setup (packages/cli/test/setup-testcontainers.ts)
		// exports: the instance-registry Redis integration tests `describe.skipIf` without them.
		N8N_TEST_REDIS_HOST:             "127.0.0.1"
		N8N_TEST_REDIS_PORT:             "${ENVE_SERVICE_REDIS_PORT}"
		TESTCONTAINERS_ENABLED:          "false"
		COREPACK_ENABLE_DOWNLOAD_PROMPT:      "0"
		PNPM_MANAGE_PACKAGE_MANAGER_VERSIONS: "false"
		// No N8N_ENCRYPTION_KEY or N8N_USER_FOLDER here: the cli service sets its own, and
		// tests given them decrypt their fixtures with the wrong key and share one folder.
	}
}

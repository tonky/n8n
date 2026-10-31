package enve

import (
	"github.com/tonky/enve/schema/v1:schema"
	"github.com/tonky/enve/pkgs:pkgs"
)

// package.json's `packageManager` pnpm, exactly (checked by tests/conformance.rs).
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
		pnpm, pkgs.nodejs & {version: "24"}, pkgs.postgresql, pkgs.redis, {pname: "tbls"},
		{pname: "curl"}, {pname: "ripgrep"}, {pname: "bash"}, {pname: "coreutils"},
		pkgs.python & {version: "3.13"}, pkgs.uv, {pname: "flock"},
		pkgs.#PlaywrightBrowsers & {version: "1.62.1", features: ["chromium-headless-shell", "ffmpeg"]},
	]
	services: {
		postgres: {
			name:        "postgres"
			port:        5438
			command:     "postgres -D \"$DATA_DIR\" -k \"$SOCKET_DIR\" -p $PORT -c shared_buffers=32MB -c work_mem=4MB -c max_connections=100 -c max_locks_per_transaction=256 -c fsync=off -c synchronous_commit=off"
			environment: {TZ: "UTC", PGTZ: "UTC"}
			lifecycle: postStart: "createdb -h 127.0.0.1 -p $PORT -U postgres n8n 2>/dev/null || true; psql -h 127.0.0.1 -p $PORT -U postgres -c \"ALTER DATABASE n8n SET timezone TO 'UTC';\" -c \"ALTER ROLE postgres SET timezone TO 'UTC';\" || true"
		}
		redis: {name: "redis", port: 6386}
		cli: {
			name:      "cli"
			command:   "sh -c 'mkdir -p node_modules/@n8n && for p in packages/@n8n/*; do [ -d \"$p\" ] && [ ! -e \"node_modules/@n8n/$(basename \"$p\")\" ] && ln -sfn \"$PWD/$p\" \"node_modules/@n8n/$(basename \"$p\")\"; done; helpers/build-workspace-deps.sh n8n... && exec node packages/cli/bin/n8n start'"
			port:      5678
			ports:     {broker: 5679}
			dependsOn: [{service: "postgres"}, {service: "redis"}]
			environment: {
				N8N_PORT:                          "${ENVE_SERVICE_CLI_PORT}"
				N8N_RUNNERS_BROKER_PORT:           "$PORT_BROKER"
				N8N_HOST:                          "127.0.0.1"
				N8N_DIAGNOSTICS_ENABLED:           "false"
				N8N_VERSION_NOTIFICATIONS_ENABLED: "false"
				N8N_ENCRYPTION_KEY:                "e2e-test-encryption-key-n8n"
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
		TZ:                                   "UTC"
		PGTZ:                                 "UTC"
		DB_TYPE:                              "postgresdb"
		DB_POSTGRESDB_HOST:                   "127.0.0.1"
		DB_POSTGRESDB_PORT:                   "${ENVE_SERVICE_POSTGRES_PORT}"
		DB_POSTGRESDB_DATABASE:               "n8n"
		DB_POSTGRESDB_USER:                   "postgres"
		DB_POSTGRESDB_PASSWORD:               ""
		PGUSER:                               "postgres"
		PGDATABASE:                           "n8n"
		QUEUE_BULL_REDIS_HOST:                "127.0.0.1"
		QUEUE_BULL_REDIS_PORT:                "${ENVE_SERVICE_REDIS_PORT}"
		N8N_TEST_REDIS_HOST:                  "127.0.0.1"
		N8N_TEST_REDIS_PORT:                  "${ENVE_SERVICE_REDIS_PORT}"
		TESTCONTAINERS_ENABLED:               "false"
		COREPACK_ENABLE_DOWNLOAD_PROMPT:      "0"
		PNPM_MANAGE_PACKAGE_MANAGER_VERSIONS: "false"
		PYTHONNOUSERSITE:                     "1"
		UV_PYTHON_PREFERENCE:                 "only-system"
		UV_PYTHON_DOWNLOADS:                  "never"
	}
}

package enve

import (
	"github.com/tonky/enve/schema/v1:schema"
	"github.com/tonky/enve/pkgs:pkgs"
)

profiles: dev: schema.#Profile & {
	name: "n8n-platform-dev"
	tools: [
		pkgs.pnpm & {version: "12"},
		pkgs.nodejs & {version: "24"},
		pkgs.postgresql,
		pkgs.redis,
		{pname: "tbls"},
	]
	services: {
		postgres: {
			name:    "postgres"
			command: "postgres -D \"$DATA_DIR\" -k /tmp -p 5432 -c shared_buffers=32MB -c work_mem=4MB -c max_connections=25 -c fsync=off -c synchronous_commit=off"
			environment: {
				TZ:   "UTC"
				PGTZ: "UTC"
			}
			lifecycle: {
				postStart: "createdb -h 127.0.0.1 -p 5432 -U postgres n8n 2>/dev/null || true; psql -h 127.0.0.1 -p 5432 -U postgres -c \"ALTER DATABASE n8n SET timezone TO 'UTC';\" -c \"ALTER ROLE postgres SET timezone TO 'UTC';\" || true"
			}
		}
		redis: {
			name: "redis"
		}
		cli: {
			name:    "cli"
			command: "sh -c '[ -f packages/cli/dist/config.js ] || pnpm turbo run build:unchecked --filter=n8n...; exec node packages/cli/bin/n8n start'"
			port:    5678
			dependsOn: [{service: "postgres"}, {service: "redis"}]
			environment: {
				N8N_PORT:                          "5678"
				N8N_HOST:                          "127.0.0.1"
				N8N_DIAGNOSTICS_ENABLED:           "false"
				N8N_VERSION_NOTIFICATIONS_ENABLED: "false"
				N8N_ENCRYPTION_KEY:                "e2e-test-encryption-key-n8n"
				N8N_USER_FOLDER:                   "/tmp/n8n-runner"
			}
			readinessProbe: {
				command: "curl -s -f --connect-timeout 1 --max-time 3 http://127.0.0.1:5678/healthz || exit 1"
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
		DB_POSTGRESDB_PORT:              "5432"
		DB_POSTGRESDB_DATABASE:          "n8n"
		DB_POSTGRESDB_USER:              "postgres"
		DB_POSTGRESDB_PASSWORD:          ""
		PGUSER:                          "postgres"
		PGDATABASE:                      "n8n"
		QUEUE_BULL_REDIS_HOST:           "127.0.0.1"
		QUEUE_BULL_REDIS_PORT:           "6379"
		TESTCONTAINERS_ENABLED:          "false"
		COREPACK_ENABLE_DOWNLOAD_PROMPT: "0"
		N8N_ENCRYPTION_KEY:              "e2e-test-encryption-key-n8n"
		N8N_USER_FOLDER:                 "/tmp/n8n-runner"
	}
}

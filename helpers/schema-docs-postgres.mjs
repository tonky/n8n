// Redirects @testcontainers/postgresql in packages/@n8n/db/scripts/schema-docs.mjs to an
// isolated throwaway database on enve's running PostgreSQL service (no Docker container).
import { execFileSync } from 'node:child_process';
import { registerHooks } from 'node:module';

if (!globalThis.__enveSchemaDocsPostgresHookRegistered) {
	globalThis.__enveSchemaDocsPostgresHookRegistered = true;
	registerHooks({
		resolve(specifier, context, nextResolve) {
			if (specifier === '@testcontainers/postgresql') {
				return { url: import.meta.url, shortCircuit: true };
			}
			return nextResolve(specifier, context);
		},
	});
}

export class PostgreSqlContainer {
	withDatabase() {
		return this;
	}

	withUsername() {
		return this;
	}

	withPassword() {
		return this;
	}

	withReuse() {
		return this;
	}

	async start() {
		const host = process.env.DB_POSTGRESDB_HOST || process.env.PGHOST || '127.0.0.1';
		const port = Number(
			process.env.DB_POSTGRESDB_PORT ||
				process.env.PGPORT ||
				process.env.ENVE_SERVICE_POSTGRES_PORT,
		);
		if (!port) {
			throw new Error(
				'Missing PostgreSQL port (DB_POSTGRESDB_PORT, PGPORT, or ENVE_SERVICE_POSTGRES_PORT)',
			);
		}
		const username = process.env.DB_POSTGRESDB_USER || process.env.PGUSER || 'postgres';
		const password = process.env.DB_POSTGRESDB_PASSWORD || process.env.PGPASSWORD || 'postgres';
		const database = `n8n_schema_docs_${process.pid}_${Date.now()}`;
		const env = { ...process.env, PGPASSWORD: password };
		const args = ['-h', host, '-p', String(port), '-U', username];

		execFileSync('dropdb', ['--if-exists', ...args, database], { env, stdio: 'pipe' });
		execFileSync('createdb', [...args, database], { env, stdio: 'pipe' });

		return {
			getHost: () => host,
			getMappedPort: () => port,
			getDatabase: () => database,
			getUsername: () => username,
			getPassword: () => password,
			getId: () => 'enve-postgres',
			stop: async () => {
				execFileSync('dropdb', ['--if-exists', ...args, database], { env, stdio: 'pipe' });
			},
		};
	}
}

// n8n-template-db.cjs <name>: builds the PostgreSQL template database the integration tests
// clone (`N8N_TEST_TEMPLATE_DB`): every migration and the auth roles, once, instead of each
// test file replaying them. Upstream's testcontainers globalSetup does this with
// `testDb.initTemplateDb`; @n8n/backend-test-utils requires vitest, so this repeats its steps
// with the built packages. Run from packages/cli, with the test run's DB_* environment.
// The packages resolve from the working directory's package, not from helpers/.
const load = require('node:module').createRequire(`${process.cwd()}/package.json`);
load('reflect-metadata');
const { GlobalConfig } = load('@n8n/config');
const { AuthRolesService, DbConnection, DbConnectionOptions } = load('@n8n/db');
const { Container } = load('@n8n/di');
const { DataSource } = load('@n8n/typeorm');

const name = process.argv[2];
if (!/^[a-z0-9_]+$/.test(name ?? '')) throw new Error(`usage: n8n-template-db.cjs <name>, not ${name}`);

const config = Container.get(GlobalConfig).database;
if (config.type !== 'postgresdb') throw new Error('a template database needs DB_TYPE=postgresdb');

// As backend-test-utils' getBootstrapDBOptions.
const bootstrap = async (sql) => {
	const connection = await new DataSource({
		type: 'postgres',
		...Container.get(DbConnectionOptions).getPostgresOverrides(),
		database: config.postgresdb.database,
		entityPrefix: config.tablePrefix,
		schema: config.postgresdb.schema,
	}).initialize();
	for (const query of sql) await connection.query(query);
	await connection.destroy();
};

(async () => {
	await bootstrap([
		`UPDATE pg_database SET datistemplate = false WHERE datname = '${name}'`,
		`DROP DATABASE IF EXISTS ${name}`,
		`CREATE DATABASE ${name}`,
	]);
	const database = config.postgresdb.database;
	config.postgresdb.database = name;
	const connection = Container.get(DbConnection);
	await connection.init();
	await connection.migrate();
	await Container.get(AuthRolesService).init();
	await connection.close();
	config.postgresdb.database = database;
	await bootstrap([`UPDATE pg_database SET datistemplate = true WHERE datname = '${name}'`]);
})().then(
	() => process.exit(0),
	(error) => {
		console.error(error);
		process.exit(1);
	},
);

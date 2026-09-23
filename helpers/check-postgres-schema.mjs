#!/usr/bin/env node
import { spawn } from 'node:child_process';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(__dirname, '..');
const DB_PKG = resolve(REPO_ROOT, 'packages/@n8n/db');

const host = process.env.PGHOST || '127.0.0.1';
const port = Number(process.env.PGPORT || 5432);
const username = process.env.PGUSER || 'postgres';
const password = process.env.PGPASSWORD || 'postgres';
const database = process.env.PGDATABASE || 'n8n';

console.log(`📦 Running TypeORM migrations against PostgreSQL at ${host}:${port}/${database}...`);
const { DataSource } = await import(resolve(DB_PKG, 'node_modules/@n8n/typeorm/dist/index.js'));
const { entities, postgresMigrations, wrapMigration } = await import(resolve(DB_PKG, 'dist/index.js'));

const dataSource = new DataSource({
  type: 'postgres',
  host,
  port,
  username,
  password,
  database,
  schema: 'public',
  entities: Object.values(entities),
  synchronize: false,
  migrationsTableName: 'migrations',
  migrations: postgresMigrations,
});

await dataSource.initialize();
postgresMigrations.forEach(wrapMigration);
const applied = await dataSource.runMigrations({ transaction: 'each' });
console.log(`✓ Applied ${applied.length} migrations to PostgreSQL.`);
await dataSource.destroy();

console.log('🔍 Running tbls diff against docs/generated/postgres-schema...');
const dsn = `postgres://${username}:${password}@${host}:${port}/${database}?sslmode=disable`;
const tblsProcess = spawn('tbls', ['diff', '-c', '.tbls.postgres.yml'], {
  cwd: REPO_ROOT,
  env: {
    ...process.env,
    TBLS_DSN: dsn,
  },
  stdio: 'inherit',
});

const exitCode = await new Promise((res) => {
  tblsProcess.on('close', res);
});

if (exitCode === 0) {
  console.log('✓ postgres schema docs are up to date.');
  process.exit(0);
} else {
  console.error(`✗ tbls diff detected schema drift (exit code ${exitCode})`);
  process.exit(exitCode ?? 1);
}

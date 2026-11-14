#!/usr/bin/env node
// pw-spec-env.mjs <dir> <spec...>: the specs grouped by the n8n env each declares.
//
// A spec's `test.use({ capability: { env: {...} } })` is the env upstream's container mode
// starts its n8n with (N8N_DEPRECATED_NODES_BLOCK, N8N_PUSH_BACKEND, TEST_ISOLATION, ...).
// run-local-isolated.mjs starts one n8n for all the specs it is given, with N8N_TEST_ENV's
// env alone: a spec run beside others without its env fails (e.g. a deprecated-node
// check expecting "this node type is deprecated"). Each line printed is one group, an n8n of its own:
// `<N8N_TEST_ENV JSON>\t<workers>\t<spec>\t<spec>...`, the caller's N8N_TEST_ENV under each
// spec's env. Shared native backends admit one worker. Other modes use `1` for
// specs tagging `@db:reset` (each such test resets the
// database: upstream gives every Playwright worker an n8n container of its own, while one
// local n8n serves all the workers, so a reset beside another worker's test failed it:
// "SQLITE_CONSTRAINT: FOREIGN KEY constraint failed"), else `-`, the caller's.
// Specs paths are relative to <dir> (the Playwright package), as the runner takes them.
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { capabilityReader } from './pw-capability.mjs';

const [dir, ...specs] = process.argv.slice(2);
const base = process.env.N8N_TEST_ENV ? JSON.parse(process.env.N8N_TEST_ENV) : {};
if (!base || Array.isArray(base) || typeof base !== 'object' || Object.values(base).some(v => typeof v !== 'string')) throw Error('N8N_TEST_ENV must contain string environment values');
const capability = capabilityReader(dir);
let proxyEnvironment;
function proxyEnv() {
  if (proxyEnvironment) return proxyEnvironment;
  const file = process.env.ENACT_NATIVE_PROXY_ENV_FILE;
  if (!file) throw Error('Native proxy capability requires its prepared environment');
  const env = JSON.parse(readFileSync(file,'utf8'));
  const names = ['HTTP_PROXY','HTTPS_PROXY','NO_PROXY','NODE_EXTRA_CA_CERTS'];
  if (Object.keys(env).some(key=>!names.includes(key)) || names.some(key=>typeof env[key] !== 'string' || !env[key])) throw Error('Invalid prepared native proxy environment');
  return proxyEnvironment = env;
}
const groups = new Map();
for (const spec of specs) {
  const source = readFileSync(resolve(dir,spec),'utf8');
  const config = capability(spec);
  const nativeProxy = process.env.ENACT_PW_BACKEND === 'shared' && config.services.length > 0 && config.services.every(name=>name==='proxy');
  const env = JSON.stringify({...base, ...config.env, ...(nativeProxy ? proxyEnv() : {})});
  const workers = process.env.ENACT_PW_BACKEND === 'shared' || source.includes('@db:reset') ? '1' : '-';
  // Specs that flip server-wide mode at runtime (e.g. setQueueMode) leave executionsConfig.mode='queue' in memory.
  const isolated = process.env.ENACT_PW_BACKEND === 'shared' && /\bsetQueueMode\s*\(/.test(source) ? spec : '';
  const key = `${env}\t${workers}\t${isolated}`;
  if (!groups.has(key)) groups.set(key,[]);
  groups.get(key).push(spec);
}
for (const [key,members] of groups) {
  const [env, workers] = key.split('\t');
  console.log([env, workers, ...members].join('\t'));
}

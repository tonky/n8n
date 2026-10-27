#!/usr/bin/env node
// pw-spec-env.mjs <dir> <spec...>: the specs grouped by the n8n env each declares.
//
// A spec's `test.use({ capability: { env: {...} } })` is the env upstream's container mode
// starts its n8n with (N8N_DEPRECATED_NODES_BLOCK, N8N_PUSH_BACKEND, TEST_ISOLATION, ...).
// run-local-isolated.mjs starts one n8n for all the specs it is given, with N8N_TEST_ENV's
// env alone: a spec run beside others without its env fails (deprecated-nodes.spec.ts:
// "this node type is deprecated"). Each line printed is one group, an n8n of its own:
// `<N8N_TEST_ENV JSON>\t<spec>\t<spec>...`, the caller's N8N_TEST_ENV under each spec's env.
// Specs paths are relative to <dir> (the Playwright package), as the runner takes them.
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const [dir, ...specs] = process.argv.slice(2);
const base = process.env.N8N_TEST_ENV ? JSON.parse(process.env.N8N_TEST_ENV) : {};

// The object literal after `capability:` in a `test.use(` call: balanced braces, a string
// (a named capability: its services make local mode skip it) is none.
function capabilityEnv(source) {
	const use = source.search(/test\.use\(\s*\{\s*capability\s*:\s*\{/);
	if (use < 0) return {};
	const start = source.indexOf('{', source.indexOf('capability', use));
	let depth = 0;
	for (let i = start; i < source.length; i++) {
		if (source[i] === '{') depth++;
		else if (source[i] === '}' && --depth === 0) {
			const literal = source.slice(start, i + 1);
			try {
				const capability = Function(`"use strict"; return (${literal});`)();
				return capability && typeof capability.env === 'object' ? capability.env : {};
			} catch {
				console.error(`pw-spec-env: unreadable capability in a spec: ${literal}`);
				process.exit(1);
			}
		}
	}
	return {};
}

const groups = new Map();
for (const spec of specs) {
	const env = JSON.stringify({ ...base, ...capabilityEnv(readFileSync(resolve(dir, spec), 'utf8')) });
	if (!groups.has(env)) groups.set(env, []);
	groups.get(env).push(spec);
}
for (const [env, members] of groups) console.log([env, ...members].join('\t'));

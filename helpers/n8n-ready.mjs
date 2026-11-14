// n8n-ready.mjs: readiness helper for local isolated n8n servers.
//
// 1. Preload mode (`node --import helpers/n8n-ready.mjs scripts/run-local-isolated.mjs ...`):
//    run-local-isolated.mjs POSTs /rest/e2e/reset and takes any answer except Express's 404
//    for ready, racing n8n's startup middleware and migrations. Wrapping `fetch` waits for
//    GET /healthz/readiness to return 200 before the first /rest/e2e/reset probe proceeds.
//
// 2. Direct probe mode (`node helpers/n8n-ready.mjs [--readiness] <origin> [<pid>]`):
//    polls GET <origin>/<health>/readiness until HTTP 200 (failing early if <pid> exits),
//    so e2e-footprints.sh can boot `node packages/cli/bin/n8n start` directly without
//    POSTing an empty `{}` body to /rest/e2e/reset.
import fs from 'node:fs';
import { pathToFileURL } from 'node:url';

const realFetch = globalThis.fetch;
const healthFrom = (env) => (env.N8N_ENDPOINT_HEALTH ?? 'healthz').replace(/^\/+/, '');
const ready = new Set();
const TIMEOUT_MS = Number(process.env.N8N_READY_TIMEOUT_MS ?? 120_000);

function pidAlive(pid) {
	if (!pid) return true;
	try {
		process.kill(pid, 0);
		return true;
	} catch (err) {
		return err.code === 'EPERM';
	}
}

async function waitForReadiness(origin, { pid = 0, health = healthFrom(process.env), strict = false } = {}) {
	const deadline = Date.now() + TIMEOUT_MS;
	let lastStatus = 'connection refused';
	while (Date.now() < deadline) {
		if (pid && !pidAlive(pid)) {
			throw new Error(`n8n process ${pid} exited before ${origin}/${health}/readiness answered 200 (last: ${lastStatus})`);
		}
		try {
			const res = await realFetch(`${origin}/${health}/readiness`);
			await res.arrayBuffer();
			lastStatus = `HTTP ${res.status}`;
			if (res.status === 200) return;
		} catch (err) {
			lastStatus = err?.message ?? String(err);
		}
		await new Promise((resolve) => setTimeout(resolve, 200));
	}
	if (strict) {
		throw new Error(`n8n at ${origin}/${health}/readiness did not become ready within ${TIMEOUT_MS}ms (last: ${lastStatus})`);
	}
}

const entryPath =
	process.argv[1] && fs.existsSync(process.argv[1]) ? fs.realpathSync(process.argv[1]) : null;
const invokedDirectly = Boolean(entryPath) && import.meta.url === pathToFileURL(entryPath).href;

if (invokedDirectly) {
	const args = process.argv.slice(2).filter((arg) => arg !== '--readiness');
	const origin = args[0];
	const pid = args[1] ? Number(args[1]) : 0;
	if (!origin) {
		console.error('usage: n8n-ready.mjs [--readiness] <origin> [<pid>]');
		process.exit(64);
	}
	try {
		await waitForReadiness(origin.replace(/\/+$/, ''), { pid, strict: true });
	} catch (err) {
		console.error(`[n8n-ready] ${err.message}`);
		process.exit(1);
	}
} else {
	globalThis.fetch = async function (input, init) {
		const url = new URL(input instanceof Request ? input.url : String(input));
		if (url.pathname.endsWith('/rest/e2e/reset') && !ready.has(url.origin)) {
			await waitForReadiness(url.origin);
			ready.add(url.origin);
		}
		return realFetch.call(this, input, init);
	};
}

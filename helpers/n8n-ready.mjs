// n8n-ready.mjs: run-local-isolated.mjs waits for n8n until it is ready, not just listening.
// playwright-runner.sh (and trace/e2e-footprints.sh) start it as
// `node --import helpers/n8n-ready.mjs scripts/run-local-isolated.mjs ...`; the flag reaches
// that process alone (Playwright and n8n, its children, don't load it).
//
// The script's readiness probe POSTs /rest/e2e/reset and takes any answer but Express's 404
// for ready. n8n listens before it migrates its database, and answers every request with
// "n8n is starting up. Please wait" (HTTP 200) until it has, then with 404 until its
// controllers are up: the probe passes early, and Playwright's global setup (its own reset)
// or the spec's first call gets one of those (upstream's race; the slower the start, the
// likelier, so a start under node-reads.mjs, or several at once, loses it every few specs).
// Here a probe of /rest/e2e/reset first waits for /healthz/readiness to answer 200, which
// n8n gives only once it has started whole.
const realFetch = globalThis.fetch;
const health = (process.env.N8N_ENDPOINT_HEALTH ?? 'healthz').replace(/^\/+/, '');
const ready = new Set();
const TIMEOUT_MS = 120_000;

async function readiness(origin) {
	const deadline = Date.now() + TIMEOUT_MS;
	while (Date.now() < deadline) {
		try {
			const res = await realFetch(`${origin}/${health}/readiness`);
			await res.arrayBuffer();
			if (res.status === 200) return;
		} catch {
			// not listening yet
		}
		await new Promise((resolve) => setTimeout(resolve, 250));
	}
	// The script's own probe reports the timeout.
}

globalThis.fetch = async function (input, init) {
	const url = new URL(input instanceof Request ? input.url : String(input));
	if (url.pathname.endsWith('/rest/e2e/reset') && !ready.has(url.origin)) {
		await readiness(url.origin);
		ready.add(url.origin);
	}
	return realFetch.call(this, input, init);
};

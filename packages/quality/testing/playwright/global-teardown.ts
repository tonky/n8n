import { execSync } from 'child_process';

import { getBackendUrl, getFrontendUrl } from './utils/url-helper';

function readParentMap(): Map<number, number> {
	const parents = new Map<number, number>();
	try {
		const output = execSync('ps -eo pid=,ppid=', { encoding: 'utf-8' });
		for (const line of output.split('\n')) {
			const parts = line.trim().split(/\s+/);
			if (parts.length < 2) continue;
			const pid = Number(parts[0]);
			const ppid = Number(parts[1]);
			if (Number.isInteger(pid) && Number.isInteger(ppid)) {
				parents.set(pid, ppid);
			}
		}
	} catch {
		// Leave map empty so unknown PIDs are never signaled.
	}
	return parents;
}

function isOwnedDescendant(pid: number, ownerPid: number, parents: Map<number, number>): boolean {
	if (!Number.isInteger(pid) || pid <= 0 || pid === ownerPid) return false;
	const seen = new Set<number>([pid]);
	let current = parents.get(pid);
	while (current !== undefined && current > 1) {
		if (current === ownerPid) return true;
		if (seen.has(current)) return false;
		seen.add(current);
		current = parents.get(current);
	}
	return false;
}

function globalTeardown() {
	console.log('🧹 Starting global teardown...');

	// Ports this run actually used (they may differ from the defaults, e.g. the
	// alt-port dev-server smoke runs the backend on 5699). A portless URL means
	// 80/443, never a dev server this run started. Killing nothing beats falling
	// back to the defaults, which are most likely the developer's own servers.
	const ports = [
		...new Set(
			[getBackendUrl(), getFrontendUrl()]
				.filter((url): url is string => !!url && URL.canParse(url))
				.map((url) => new URL(url).port)
				.filter((port) => /^\d+$/.test(port)),
		),
	];

	const parents = readParentMap();
	const ownerPid = process.pid;

	for (const port of ports) {
		try {
			// Only inspect TCP LISTEN sockets so connected client processes (including
			// this Playwright runner) are never matched, and only signal listeners that
			// are descendants of this invocation.
			const pids = [
				...new Set(
					execSync(`lsof -tiTCP:${port} -sTCP:LISTEN`, { encoding: 'utf-8' })
						.trim()
						.split('\n')
						.map((raw) => Number(raw.trim()))
						.filter((pid) => isOwnedDescendant(pid, ownerPid, parents)),
				),
			];

			if (pids.length > 0) {
				console.log(`- Killing owned listener process(es) ${pids.join(', ')} on port ${port}`);
				for (const pid of pids) {
					try {
						process.kill(pid, 'SIGKILL');
					} catch {
						// Ignore races when a child exits alongside its parent.
					}
				}
			} else {
				console.log(`- No owned listener process found on port ${port}`);
			}
		} catch {
			// lsof returns non-zero exit code if no listener is found
			console.log(`- No owned listener process found on port ${port}`);
		}
	}

	console.log('🏁 Global teardown completed');
}

// eslint-disable-next-line import-x/no-default-export
export default globalTeardown;

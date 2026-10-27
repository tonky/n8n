// =============================================================================================
// playwright-attribution.mjs - A Playwright reporter saying which spec files skipped tests
// =============================================================================================
// A spec's footprint (e2e-footprint.mjs) holds what its run read, not that a test skipped: a
// `test.skip`/`test.fixme`, a conditional skip (`test.skip(({ browserName }) => …)`, a
// project's), a `describe.skip`, a file skipped whole read only what decided the skip. One
// line per spec file to $ENACT_SKIPS_FILE, in enact's attribution record (`enact handbook
// scoping`, "Recorder contract"):
//   {"target": "<spec file>", "outcome": "passed|skipped|failed", "skipped": <some skipped>}
// The footprint is then kept, marked as skipped on this platform: planning on another runs
// it on every change. A test that never ran (an interrupted run) counts as skipped; its run
// failed, which already makes the footprint incomplete.
import fs from 'node:fs';

export default class EnactAttribution {
	printsToStdio() {
		return false;
	}

	onBegin(_config, suite) {
		this.suite = suite;
	}

	onEnd() {
		const out = process.env.ENACT_SKIPS_FILE;
		if (!out || !this.suite) return;
		const files = new Map();
		for (const test of this.suite.allTests()) {
			const file = files.get(test.location.file) ?? { tests: 0, skipped: 0, failed: 0 };
			const outcome = test.outcome();
			file.tests += 1;
			if (outcome === 'skipped') file.skipped += 1;
			if (outcome === 'unexpected') file.failed += 1;
			files.set(test.location.file, file);
		}
		const lines = [...files].map(([target, { tests, skipped, failed }]) => {
			const outcome = failed ? 'failed' : skipped === tests ? 'skipped' : 'passed';
			return `${JSON.stringify({ target, outcome, skipped: skipped > 0, reads: [] })}\n`;
		});
		fs.appendFileSync(out, lines.join(''));
	}
}

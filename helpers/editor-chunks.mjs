#!/usr/bin/env node
// Ensures packages/frontend/editor-ui/dist/.enact-editor-chunks.json maps the current
// editor-ui Vite bundle without letting the metadata file itself perturb vite-chunks.mjs's
// dist file-list hash (`served(dist)`).
import { execFileSync, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const helperDir = path.dirname(fileURLToPath(import.meta.url));
const rawRoot = path.resolve(process.env.ENACT_FOOTPRINT_ROOT ?? path.resolve(helperDir, '..'));
const repoRoot = fs.existsSync(rawRoot) ? fs.realpathSync(rawRoot) : rawRoot;
const distRel = 'packages/frontend/editor-ui/dist';
const distDir = path.join(repoRoot, distRel);
const rawOut = process.argv[2]
	? path.resolve(process.argv[2])
	: path.join(distDir, '.enact-editor-chunks.json');
const outParent = path.dirname(rawOut);
const outPath = fs.existsSync(outParent)
	? path.join(fs.realpathSync(outParent), path.basename(rawOut))
	: rawOut;
const outInDist = outPath.startsWith(distDir + path.sep)
	? path.relative(distDir, outPath).split(path.sep).join('/')
	: null;

function resolveRecordersJs() {
	if (process.env.ENACT_RECORDERS_DIR) {
		const candidate = path.join(process.env.ENACT_RECORDERS_DIR, 'js');
		if (fs.existsSync(path.join(candidate, 'vite-chunks.mjs'))) return candidate;
	}
	const enactBin = process.env.ENACT_EXE || process.env.ENACT_BIN || 'enact';
	try {
		const dir = execFileSync(enactBin, ['recorder-dir'], {
			encoding: 'utf8',
			stdio: ['ignore', 'pipe', 'ignore'],
		}).trim();
		const candidate = path.join(dir, 'js');
		if (fs.existsSync(path.join(candidate, 'vite-chunks.mjs'))) return candidate;
	} catch {
		// fall back to workspace relative paths
	}
	for (const rel of [
		'../../../../crates/enact-runner/recorders/js',
		'../../crates/enact-runner/recorders/js',
		'trace',
	]) {
		const candidate = path.resolve(helperDir, rel);
		if (fs.existsSync(path.join(candidate, 'vite-chunks.mjs'))) return candidate;
	}
	return path.join(helperDir, 'trace');
}

function servedWithoutMeta(dir, base = dir, found = []) {
	for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
		const full = path.join(dir, entry.name);
		if (entry.isDirectory()) {
			servedWithoutMeta(full, base, found);
			continue;
		}
		const rel = path.relative(base, full).split(path.sep).join('/');
		if (rel === outInDist || (outInDist && rel.startsWith(`${outInDist}.`))) continue;
		found.push(rel);
	}
	return found.sort();
}

if (fs.existsSync(path.join(distDir, 'index.html'))) {
	const servedFiles = servedWithoutMeta(distDir);
	const expectedKey = createHash('sha256').update(servedFiles.join('\n')).digest('hex');
	try {
		const cached = JSON.parse(fs.readFileSync(outPath, 'utf8'));
		if (cached?.version === 1 && cached?.key === expectedKey && cached?.outputs && typeof cached.outputs === 'object') {
			process.exit(0);
		}
	} catch {
		// missing or stale; regenerate below
	}
	if (outInDist) {
		fs.rmSync(outPath, { force: true });
	}
}

const viteChunks = path.join(resolveRecordersJs(), 'vite-chunks.mjs');
const res = spawnSync(
	process.execPath,
	[viteChunks, '--root', 'packages/frontend/editor-ui', '--public-path', '/{{BASE_PATH}}/', outPath],
	{
		cwd: repoRoot,
		env: { ...process.env, ENACT_FOOTPRINT_ROOT: repoRoot },
		stdio: 'inherit',
	},
);
process.exit(res.status ?? 1);

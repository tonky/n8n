#!/usr/bin/env node
// =============================================================================================
// e2e-footprint.mjs write <dir> <chunks.json> <spec>=<exit status>... - The e2e specs' map
// =============================================================================================
// enact footprints of the Playwright e2e specs, recorded per spec file (e2e-footprints.sh runs
// each wanted spec alone, through run-local-isolated.mjs: an n8n server of its own, started
// for it, on a throwaway SQLite database). A spec's test passes through three processes'
// code: Playwright's (the spec, its pages, fixtures, workflows), the n8n server's (the
// workspace packages' builds it loads, its task runner's) and the browser's (the editor's
// bundle the server serves). A footprint holds all three:
//   - every Node.js process of the spec's run recorded its reads (node-reads.mjs, in
//     <dir>/node/<n>/ for the n-th spec);
//   - a workspace package's build file (`<pkg>/dist/x.js`, tsc's) stands for the sources its
//     source map names (`x.js.map`): a change to one of cli's sources reaches the specs whose
//     server loaded its build, not every spec. A file the build copied (icons, `.node.json`)
//     stands for its original, a listed or probed build path for its source directory's
//     (a resolver's misses, a loader's `exists`). Any other build file stays itself (the
//     pipeline's derived rule: any change to its package). Each package mapped so has its own root files
//     (package.json, tsconfigs: how it was built) read too.
//   - the editor's bundle: the server copies every script and stylesheet of
//     packages/frontend/editor-ui/dist into its static cache as it starts (those reads say
//     nothing of the spec, left out) and serves them from there; what it served the spec's
//     browser (node-reads' `served`) stands for what those outputs were made from
//     (<chunks.json>, editor-chunks.mjs). An output that map doesn't hold makes the spec
//     partial.
// `shared` (laid over every spec): the runner's own scripts, and what the editor's build
// reads that is no module (its configuration, Sass partials, public files: the chunk map's
// `build_inputs`).
// A spec whose run failed is incomplete (its exit status); one a process left no record for,
// or whose browser fetched an output nothing maps, is partial. A spec whose run skipped tests
// (<dir>/skips/<n>.jsonl, playwright-attribution.mjs's lines) is kept, marked as skipped on
// this platform (`skipped_on`): planning on another runs it on every change; a run that left
// no such file is partial. $ENACT_FOOTPRINT_TARGETS, when set, lists the specs worth
// recording; the others are left out.
import fs from 'node:fs';
import path from 'node:path';

const RECORDER = 'e2e-footprint.mjs/1';
const EDITOR = 'packages/frontend/editor-ui/';
const EDITOR_DIST = `${EDITOR}dist/`;
// What runs the specs and records them, read by no recorded process (bash, or the preload).
const HARNESS = [
	'helpers/playwright-runner.sh',
	'helpers/n8n-ready.mjs',
	'helpers/build-workspace-deps.sh',
	'helpers/trace/e2e-footprints.sh',
	'helpers/trace/e2e-footprint.mjs',
	'helpers/trace/editor-chunks.mjs',
	'helpers/trace/node-reads.mjs',
];
// How long a spec's processes may take to write their records once its run ended (the n8n
// server shuts down after run-local-isolated.mjs exits).
const SETTLE_MS = Number(process.env.ENACT_E2E_SETTLE_MS ?? 60_000);

const root = path.resolve(process.env.ENACT_FOOTPRINT_ROOT ?? process.cwd());
// The platform as enact names it (`skipped_on`).
const PLATFORM = process.platform;
const exists = (rel) => fs.existsSync(path.join(root, rel));

class Footprint {
	constructor() {
		this.reads = new Set();
		this.present = new Set();
		this.probes = new Set();
		this.dirs = new Set();
		this.served = new Set();
		this.opaque = new Set();
	}
}

const alive = (pid) => {
	try {
		process.kill(pid, 0);
		return true;
	} catch (error) {
		return error.code === 'EPERM';
	}
};
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/** A process' record (`<stem>.json`), else a worker's log (`<stem>.jsonl`). */
function record(stem) {
	try {
		return JSON.parse(fs.readFileSync(`${stem}.json`, 'utf8'));
	} catch (error) {
		if (error.code !== 'ENOENT') throw error;
	}
	const out = {};
	const lines = fs.readFileSync(`${stem}.jsonl`, 'utf8').split('\n');
	for (const line of lines.slice(0, -1)) {
		const [kind, rel] = JSON.parse(line);
		(out[kind] ??= []).push(rel);
	}
	return out;
}

/** The records in a spec's directory, once its processes ended (or SETTLE_MS passed). */
async function nodeRecords(directory, deadline) {
	const fp = new Footprint();
	let names = [];
	for (;;) {
		try {
			names = fs.readdirSync(directory);
		} catch {
			names = [];
		}
		const waiting = names
			.filter((n) => n.endsWith('-0.started'))
			.filter((n) => !names.includes(n.replace(/\.started$/, '.json')))
			.map((n) => Number(n.split('-')[0]))
			.filter(alive);
		if (!waiting.length || Date.now() > deadline) break;
		await sleep(250);
	}
	if (!names.some((n) => n.endsWith('.started'))) fp.opaque.add('no Node.js process recorded for it');
	for (const name of names.sort()) {
		if (!name.endsWith('.started')) continue;
		const stem = path.join(directory, name.slice(0, -'.started'.length));
		let found;
		try {
			found = record(stem);
		} catch {
			const argv = fs.readFileSync(path.join(directory, name), 'utf8').slice(0, 200);
			fp.opaque.add(`a Node.js process ended without its record (${argv})`);
			continue;
		}
		for (const kind of ['reads', 'present', 'probes', 'dirs', 'served']) {
			for (const rel of found[kind] ?? []) fp[kind].add(rel);
		}
	}
	return fp;
}

/** Whether the n-th spec's run skipped tests (its reporter's lines, the attribution record);
 *  null: it left no record. */
function skippedTests(directory, n) {
	let text;
	try {
		text = fs.readFileSync(path.join(directory, 'skips', `${n}.jsonl`), 'utf8');
	} catch (error) {
		if (error.code === 'ENOENT') return null;
		throw error;
	}
	return text
		.split('\n')
		.filter((line) => line.trim())
		.map((line) => JSON.parse(line))
		.some((line) => line.skipped === true || line.outcome === 'skipped');
}

const sameFile = (a, b) => {
	try {
		return fs.readFileSync(path.join(root, a)).equals(fs.readFileSync(path.join(root, b)));
	} catch {
		return false;
	}
};
const sourceMaps = new Map();
/** The repository files a workspace build file was made from: a script's by its source map, a
 *  copied file's its original; null: none (no map, or it names nothing of the repository's;
 *  a generated file). */
function compiledFrom(rel) {
	if (sourceMaps.has(rel)) return sourceMaps.get(rel);
	let sources = null;
	// A map read by itself (a stack trace's source-mapped frames) stands for its build file.
	const built = rel.endsWith('.map') ? rel.slice(0, -'.map'.length) : rel;
	if (/\.(c|m)?js$/.test(built)) {
		try {
			const map = JSON.parse(fs.readFileSync(path.join(root, `${built}.map`), 'utf8'));
			const base = path.join(path.dirname(path.join(root, built)), map.sourceRoot ?? '');
			const found = (map.sources ?? [])
				.map((s) => path.relative(root, path.resolve(base, s)).split(path.sep).join('/'))
				.filter((s) => !s.startsWith('..') && !s.split('/').includes('node_modules') && !s.includes('/dist/'))
				.filter(exists);
			sources = found.length ? found : null;
		} catch {
			sources = null;
		}
	} else {
		// A file the build copied (an icon, a node's `.node.json`): the package's file it is
		// byte for byte, beside dist or under src/. A generated one has none (its package).
		const pkg = packageOf(rel);
		const rest = rel.slice(pkg.length + '/dist/'.length);
		const copied = [`${pkg}/${rest}`, `${pkg}/src/${rest}`].find((s) => sameFile(s, rel));
		sources = copied ? [copied] : null;
	}
	sourceMaps.set(rel, sources);
	return sources;
}
const packageOf = (rel) => rel.slice(0, rel.indexOf('/dist/'));
const isDir = (rel) => {
	try {
		return fs.statSync(path.join(root, rel)).isDirectory();
	} catch {
		return false;
	}
};
const sourceDirs = new Map();
/** The source directory a build directory is laid out from (tsc mirrors its rootDir, a dual
 *  build each of dist/cjs and dist/esm), by a source map in it or in the nearest directory
 *  above that has one; else the package's src/. null: none (a package without src/). */
function sourceDirOf(dir) {
	if (sourceDirs.has(dir)) return sourceDirs.get(dir);
	const pkg = packageOf(`${dir}/`);
	let found = null;
	for (let d = dir, below = ''; d.length > pkg.length; below = `/${path.posix.basename(d)}${below}`, d = path.posix.dirname(d)) {
		let names = [];
		try {
			names = fs.readdirSync(path.join(root, d));
		} catch {
			continue; // not built: its parent's layout
		}
		const map = names.find((n) => n.endsWith('.js.map'));
		const sources = map && compiledFrom(`${d}/${map.slice(0, -'.map'.length)}`);
		if (sources) {
			const source = sources.find((s) => s.startsWith(`${pkg}/`));
			if (source) found = path.posix.dirname(source) + below;
			if (found) break;
		}
	}
	if (!found) {
		const rest = dir.slice(`${pkg}/dist`.length);
		if (isDir(`${pkg}/src`)) found = `${pkg}/src${rest}`;
	}
	sourceDirs.set(dir, found);
	return found;
}
/** A build directory's listing stands for its source directory's: adding a source adds an
 *  output there. One without a source directory (generated) stays itself. */
function listedFrom(dir, mapped) {
	if (!`${dir}/`.includes('/dist/')) return dir;
	const source = sourceDirOf(dir);
	if (!source || !isDir(source)) return dir;
	mapped.add(packageOf(`${dir}/`));
	return source;
}
// tsc's outputs by the sources they're compiled from.
const COMPILED = [
	[/\.d\.ts(\.map)?$/, ['.ts', '.tsx']],
	[/\.js(\.map)?$/, ['.ts', '.tsx', '.js']],
	[/\.mjs(\.map)?$/, ['.mts', '.mjs']],
	[/\.cjs(\.map)?$/, ['.cts', '.cjs']],
];
/** The paths a probe of a build path stands for: a present output's sources (deleting one
 *  deletes it), a missing one's would-be sources (adding one makes it: `x.module.js` from
 *  `x.module.ts`, `x/` from `x/`, a resolver's `x.json` from `x.json`). null: none known. */
function probedFrom(rel) {
	if (exists(rel)) return compiledFrom(rel);
	const dir = sourceDirOf(path.posix.dirname(rel));
	if (!dir) return null;
	const name = path.posix.basename(rel);
	const compiled = COMPILED.find(([output]) => output.test(name));
	if (!compiled) return [`${dir}/${name}`];
	const stem = name.replace(compiled[0], '');
	return compiled[1].map((ext) => `${dir}/${stem}${ext}`);
}

/** Rewrites `fp` in place: build files to their sources, the editor's served outputs to theirs. */
function mapBuilt(fp, chunks, mapped) {
	const viaMaps = (files, into) => {
		for (const rel of files) {
			const sources = rel.includes('/dist/') ? compiledFrom(rel) : null;
			if (sources) {
				sources.forEach((s) => into.add(s));
				mapped.add(packageOf(rel));
			} else {
				into.add(rel);
			}
		}
	};
	const reads = new Set();
	const servedDirectly = [];
	for (const rel of fp.reads) {
		if (rel.startsWith(EDITOR_DIST)) {
			const name = rel.slice(EDITOR_DIST.length);
			// The server's start copies index.html and every script and stylesheet; it serves
			// other files (fonts, wasm, images) from dist itself, as the browser asks.
			if (name !== 'index.html' && !/\.(js|css)$/.test(name)) servedDirectly.push(name);
			continue;
		}
		reads.add(rel);
	}
	const files = new Set();
	viaMaps(reads, files);
	const present = new Set();
	viaMaps(
		[...fp.present].filter((rel) => !rel.startsWith(EDITOR_DIST)),
		present,
	);
	for (const name of [...fp.served, ...servedDirectly]) {
		if (name.startsWith('types/')) continue; // the node and credential types the server wrote
		const sources = chunks.outputs[name];
		if (sources) viaMaps(sources, files);
		else if (exists(`${EDITOR}public/${name}`)) files.add(`${EDITOR}public/${name}`);
		else fp.opaque.add(`the browser fetched ${name}, which no output of the editor's build maps`);
	}
	fp.reads = files;
	fp.present = present;
	fp.dirs = new Set(
		[...fp.dirs].filter((d) => !d.startsWith(EDITOR_DIST.slice(0, -1))).map((d) => listedFrom(d, mapped)),
	);
	const probes = new Set();
	for (const rel of fp.probes) {
		if (rel.startsWith(EDITOR_DIST.slice(0, -1))) continue;
		const sources = rel.includes('/dist/') ? probedFrom(rel) : null;
		if (sources) {
			sources.forEach((s) => probes.add(s));
			mapped.add(packageOf(rel));
		} else {
			probes.add(rel);
		}
	}
	fp.probes = probes;
	fp.served = new Set();
}

function entry(fp) {
	const files = new Set([...fp.reads, ...fp.present]);
	const out = { files: [...files].sort() };
	const probes = [...fp.probes].filter((p) => !files.has(p)).sort();
	if (probes.length) out.probes = probes;
	if (fp.dirs.size) out.dirs = [...fp.dirs].sort().map((d) => `dir:${d}`);
	return out;
}

/** A package's root files: how its build was made (package.json, tsconfigs). */
function buildConfig(pkg) {
	try {
		return fs
			.readdirSync(path.join(root, pkg), { withFileTypes: true })
			.filter((e) => e.isFile() && !e.name.endsWith('.md'))
			.map((e) => `${pkg}/${e.name}`);
	} catch {
		return [];
	}
}

async function write(directory, chunksFile, results) {
	const outDir = process.env.ENACT_FOOTPRINT_DIR;
	if (!outDir) throw new Error('ENACT_FOOTPRINT_DIR is not set');
	const chunks = JSON.parse(fs.readFileSync(chunksFile, 'utf8'));
	const listed = process.env.ENACT_FOOTPRINT_TARGETS;
	const wanted = listed
		? new Set(fs.readFileSync(listed, 'utf8').split('\n').map((l) => l.trim().split('::')[0]).filter(Boolean))
		: null;
	const mapped = new Set();
	const targets = {};
	const opaque = {};
	const deadline = Date.now() + SETTLE_MS;
	for (const [index, result] of results.entries()) {
		const at = result.lastIndexOf('=');
		const spec = result.slice(0, at);
		const status = result.slice(at + 1);
		if (wanted && !wanted.has(spec)) continue;
		const fp = await nodeRecords(path.join(directory, 'node', String(index + 1)), deadline);
		const skipped = skippedTests(directory, index + 1);
		if (skipped === null) fp.opaque.add('its run left no record of the tests it skipped');
		mapBuilt(fp, chunks, mapped);
		fp.reads.add(spec);
		const target = entry(fp);
		if (skipped) target.skipped_on = [PLATFORM];
		if (fp.opaque.size) opaque[spec] = [...fp.opaque].sort();
		if (status !== '0') target.outcome = { incomplete: { exit: /^-?\d+$/.test(status) ? Number(status) : 1 } };
		else if (fp.opaque.size) target.outcome = 'partial';
		targets[spec] = target;
	}
	if (!Object.keys(targets).length) return;
	const shared = new Footprint();
	for (const rel of [...HARNESS, ...(chunks.build_inputs ?? [])]) if (exists(rel)) shared.reads.add(rel);
	for (const pkg of mapped) for (const rel of buildConfig(pkg)) shared.reads.add(rel);
	fs.mkdirSync(outDir, { recursive: true });
	const out = path.join(outDir, `e2e-shard${process.env.ENACT_SHARD_INDEX ?? 1}-${process.pid}.json`);
	fs.writeFileSync(
		`${out}.tmp`,
		JSON.stringify({ version: 1, recorder: RECORDER, outcomes: true, shared: entry(shared), targets }),
	);
	fs.renameSync(`${out}.tmp`, out);
	const values = Object.values(targets);
	console.error(
		`e2e-footprint: ${values.length} spec files (${values.filter((t) => t.outcome?.incomplete).length} failed, ` +
			`${values.filter((t) => t.outcome === 'partial').length} partial, ${values.filter((t) => t.skipped_on).length} skipping), ` +
			`${fs.statSync(out).size >> 10} KB -> ${out}`,
	);
	for (const [spec, why] of Object.entries(opaque)) console.error(`  ${spec}: ${why.join('; ').slice(0, 300)}`);
}

const [command, ...args] = process.argv.slice(2);
if (command === 'write' && args.length >= 2) {
	await write(args[0], args[1], args.slice(2));
} else {
	console.error('usage: e2e-footprint.mjs write <dir> <chunks.json> <spec>=<exit status>...');
	process.exit(64);
}

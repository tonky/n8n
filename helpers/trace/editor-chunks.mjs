#!/usr/bin/env node
// =============================================================================================
// editor-chunks.mjs <out.json> - What each file of the editor's build was made from
// =============================================================================================
// The e2e footprints' browser half (e2e-footprint.mjs): the browser runs the editor's bundle
// (packages/frontend/editor-ui/dist), never the repository's files, so a spec's footprint
// joins the build outputs its page fetched with what each was made from. The served build is
// upstream's (`build`: `vite build`, through turbo); this builds it again, as that script does,
// into a scratch directory with one plugin more (enactChunks below), and keeps only what the
// plugin wrote:
//   {version, outputs: {<dist-relative output>: [<repository file>...]}, held: [...]}
//   - a chunk: every module bundled into it (shaken-out code and unused imports included);
//   - a module no output holds (shaken out whole): the outputs of its nearest held importers,
//     where an added side effect would land;
//   - a CSS file: the stylesheets (and SFCs) of the chunks importing it; an asset: the files it
//     was copied from;
//   `build_inputs`: what the build reads that is no module of the bundle, every spec's: the
//   files the config imports (vite.config.mts, its plugins: Vite's configFileDependencies) and,
//   in each package a module came from, the tracked files that are neither a module nor code
//   under src/ (manifests, tsconfigs, Sass partials a stylesheet `@use`s, data a plugin reads).
// Paths are the repository's; node_modules and virtual modules hold none. The scratch build
// must name the same outputs as the served one (names carry content hashes): if they differ,
// the served build is not this tree's, and the map isn't written (exit 1).
// <out.json> is kept beside its key (the served build's output names): a later run with the
// same build reuses it.
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const [outArg] = process.argv.slice(2);
if (!outArg) {
	console.error('usage: editor-chunks.mjs <out.json>');
	process.exit(64);
}
const repo = path.resolve(process.env.ENACT_FOOTPRINT_ROOT ?? process.cwd());
const editor = path.join(repo, 'packages/frontend/editor-ui');
const dist = path.join(editor, 'dist');
const out = path.resolve(outArg);

/** The served build's files, dist-relative, sorted (the map's key). */
function served(dir, base = dir, found = []) {
	for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
		const file = path.join(dir, entry.name);
		if (entry.isDirectory()) served(file, base, found);
		else found.push(path.relative(base, file).split(path.sep).join('/'));
	}
	return found.sort();
}

if (!fs.existsSync(path.join(dist, 'index.html'))) {
	console.error(`editor-chunks: ${dist} holds no build`);
	process.exit(1);
}
const servedFiles = served(dist);
const key = createHash('sha256').update(servedFiles.join('\n')).digest('hex');
try {
	const cached = JSON.parse(fs.readFileSync(out, 'utf8'));
	if (cached.key === key) {
		console.error(`editor-chunks: ${out} maps this build (${servedFiles.length} files)`);
		process.exit(0);
	}
} catch {
	// none yet, or unreadable: build it
}

const root = repo + path.sep;
const inRepo = (id) => {
	const file = String(id).split('?')[0].split('#')[0];
	if (file.startsWith('\0') || !path.isAbsolute(file) || !file.startsWith(root)) return undefined;
	const relative = file.slice(root.length);
	if (relative.split(path.sep).includes('node_modules') || !fs.existsSync(file)) return undefined;
	return relative.split(path.sep).join('/');
};
const isStylesheet = (id) => /\.(css|scss|sass|less|pcss|styl)$/.test(String(id).split('?')[0]) ||
	/[?&]type=style\b/.test(String(id));

let result = null;
let configInputs = [];
const enactChunks = {
	name: 'enact-chunks',
	apply: 'build',
	enforce: 'post',
	configResolved(config) {
		configInputs = (config.configFileDependencies ?? []).map((f) => inRepo(path.resolve(f))).filter(Boolean);
	},
	generateBundle(_options, bundle) {
		const outputs = {};
		const add = (output, id) => {
			const file = id ? inRepo(id) : undefined;
			if (file) (outputs[output] ??= new Set()).add(file);
		};
		const holders = new Map();
		for (const [fileName, item] of Object.entries(bundle)) {
			outputs[fileName] ??= new Set();
			if (item.type === 'chunk') {
				const ids = new Set([...Object.keys(item.modules ?? {}), ...(item.moduleIds ?? [])]);
				if (item.facadeModuleId) ids.add(item.facadeModuleId);
				for (const id of ids) {
					add(fileName, id);
					if (!holders.has(id)) holders.set(id, new Set());
					holders.get(id).add(fileName);
				}
				for (const css of item.viteMetadata?.importedCss ?? []) {
					outputs[css] ??= new Set();
					for (const id of ids) if (isStylesheet(id) || /\.vue$/.test(String(id).split('?')[0])) add(css, id);
				}
				for (const asset of item.viteMetadata?.importedAssets ?? []) outputs[asset] ??= new Set();
			} else {
				const sources = [...(item.originalFileNames ?? []), ...(item.originalFileName ? [item.originalFileName] : [])];
				for (const source of sources) add(fileName, path.isAbsolute(source) ? source : path.resolve(editor, source));
			}
		}
		// Modules no output holds: the outputs of their nearest held importers.
		for (const id of this.getModuleIds()) {
			if (holders.has(id) || !inRepo(id)) continue;
			const seen = new Set([id]);
			const queue = [id];
			const found = new Set();
			while (queue.length) {
				const info = this.getModuleInfo(queue.shift());
				for (const importer of [...(info?.importers ?? []), ...(info?.dynamicImporters ?? [])]) {
					if (seen.has(importer)) continue;
					seen.add(importer);
					const held = holders.get(importer);
					if (held) held.forEach((output) => found.add(output));
					else queue.push(importer);
				}
			}
			found.forEach((output) => add(output, id));
		}
		const modules = new Set();
		for (const id of this.getModuleIds()) {
			const file = inRepo(id);
			if (file) modules.add(file);
		}
		result = {
			outputs: Object.fromEntries(
				Object.entries(outputs)
					.sort(([a], [b]) => a.localeCompare(b))
					.map(([output, files]) => [output, [...files].sort()]),
			),
			modules: [...modules].sort(),
		};
	},
};

// Code no bundle holds: a module of src/ shaken out or never imported (an import would change
// a held file), tests, stories and docs. Everything else tracked in a contributing package.
const CODE = /\.(m?[jt]sx?|cjs|cts|vue)$/;
const NOT_BUILT = /(^|\/)(__tests__|__mocks__|test|tests|e2e|\.storybook)\/|\.(test|spec|stories)\.[^/]+$|\.md$/;
function buildInputs(modules, config) {
	const held = new Set(modules);
	const packages = new Set();
	for (const file of modules) {
		for (let dir = path.dirname(file); dir !== '.' && dir !== ''; dir = path.dirname(dir)) {
			if (fs.existsSync(path.join(repo, dir, 'package.json'))) {
				packages.add(dir);
				break;
			}
		}
	}
	const tracked = execFileSync('git', ['ls-files', '-z', '--', ...packages], { cwd: repo, maxBuffer: 1 << 28 })
		.toString()
		.split('\0')
		.filter(Boolean);
	const inputs = new Set(config);
	for (const file of tracked) {
		if (held.has(file) || NOT_BUILT.test(file)) continue;
		const pkg = [...packages].find((p) => file.startsWith(p + '/'));
		if (CODE.test(file) && file.slice(pkg.length + 1).startsWith('src/')) continue;
		inputs.add(file);
	}
	return [...inputs].sort();
}

const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'enact-editor-chunks-'));
const started = Date.now();
try {
	// As the package's `build` script runs it (cross-env VUE_APP_PUBLIC_PATH, from the package).
	process.env.VUE_APP_PUBLIC_PATH = '/{{BASE_PATH}}/';
	process.chdir(editor);
	const vitePackage = path.join(editor, 'node_modules/vite');
	const { build } = await import(pathToFileURL(path.join(fs.realpathSync(vitePackage), 'dist/node/index.js')).href);
	await build({
		root: editor,
		configFile: path.join(editor, 'vite.config.mts'),
		logLevel: 'warn',
		plugins: [enactChunks],
		build: { outDir: scratch, emptyOutDir: true },
	});
	if (!result) throw new Error('the enact-chunks plugin saw no bundle');
	const built = served(scratch);
	const missing = servedFiles.filter((f) => !built.includes(f));
	const extra = built.filter((f) => !servedFiles.includes(f));
	if (missing.length || extra.length) {
		console.error(
			`editor-chunks: the served build in ${dist} is not this tree's: ${missing.length} of its files this build doesn't make (${missing.slice(0, 5).join(', ')}), ${extra.length} it lacks (${extra.slice(0, 5).join(', ')})`,
		);
		process.exit(1);
	}
	result.build_inputs = buildInputs(result.modules, configInputs);
	fs.mkdirSync(path.dirname(out), { recursive: true });
	fs.writeFileSync(`${out}.${process.pid}.tmp`, JSON.stringify({ version: 1, key, ...result }));
	fs.renameSync(`${out}.${process.pid}.tmp`, out);
	console.error(
		`editor-chunks: ${Object.keys(result.outputs).length} outputs, ${result.modules.length} repository modules, ${result.build_inputs.length} build inputs -> ${out} (${((Date.now() - started) / 1000).toFixed(1)} s)`,
	);
} finally {
	fs.rmSync(scratch, { recursive: true, force: true });
}

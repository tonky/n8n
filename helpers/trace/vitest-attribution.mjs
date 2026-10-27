// =============================================================================================
// vitest-attribution.mjs - A vitest reporter writing enact's attribution file
// =============================================================================================
// `enact trace run --attribution <file>` traces one vitest run of many test files and needs to
// know, per test file, which module files vitest's main process loaded for it: the main
// process transforms every module, so the trace alone can't say whose a read was. This
// reporter writes one JSON line per test file to $ENACT_ATTRIBUTION_FILE (the contract:
// `enact handbook scoping`, "Recorder contract"):
//   {"target": "<test file>", "outcome": "passed|skipped|failed|partial", "skipped": <bool>, "reads": [...]}
// - skipped: some test of the file didn't run (`.skip`, `.todo`, `skipIf`/`runIf`, `ctx.skip()`,
//   `.only` elsewhere, a file skipped whole): enact keeps its footprint, marked as skipped on
//   this platform, whatever its outcome (the skip contract every recorder shares).
// - reads: every module the file's worker executed (`diagnostic().importDurations`, from the
//   worker's module execution log: setup files, the file, what it imported, dynamic imports
//   and mocks included), as file paths.
// - It adds vitest-marker.mjs (a copy under the root's node_modules) as the first setup file: each worker marks its test file, so
//   the tracer gives the worker's own reads (fixtures, natively loaded packages, processes it
//   starts) to that file, and enact's Node recorder (`--node-functions`) the functions the
//   worker runs.
// - Fail closed: a passing file whose list may be partial (vitest capped it, or it doesn't
//   list the file itself) or whose worker ran other files too (not one forked process per
//   file) is `partial`; a failed file, and one an unhandled error is pinned on, is `failed`.
//   An unhandled error pinned on no file fails every file.
// Vitest 3.2 to 5: `onInit`, `onTestModuleEnd`, `onTestRunEnd`, `TestModule.diagnostic()`.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const MARKER_SOURCE = fileURLToPath(new URL('./vitest-marker.mjs', import.meta.url));
const OUT = process.env.ENACT_ATTRIBUTION_FILE;

/** The file a module id names, or null (virtual modules, ids that aren't paths). */
export function modulePath(id) {
  let file = String(id).split('?')[0].split('#')[0];
  if (file.startsWith('file://')) file = fileURLToPath(file);
  if (file.startsWith('/@fs/')) file = file.slice('/@fs'.length);
  if (file.startsWith('\0') || !path.isAbsolute(file)) return null;
  return file;
}

/** Whether the project runs each test file in a forked process of its own. */
function forkPerFile(config) {
  const isolate = config.poolOptions?.forks?.isolate ?? config.isolate ?? true;
  return config.pool === 'forks' && isolate !== false && !config.poolOptions?.forks?.singleFork;
}

/** Whether some test of the module didn't run: skipped or todo (its mode, or its result). */
export function skippedSome(testModule) {
  if (testModule.state() === 'skipped') return true;
  for (const test of testModule.children.allTests()) {
    const mode = test.options?.mode;
    if (mode === 'skip' || mode === 'todo' || test.result()?.state === 'skipped') return true;
  }
  return false;
}

export default class EnactAttribution {
  onInit(vitest) {
    const projects = vitest.projects?.length ? vitest.projects : [vitest.getRootProject?.()].filter(Boolean);
    const configs = [vitest.config, ...projects.map((project) => project.config)];
    for (const config of configs) {
      if (!config) continue;
      // Vitest 4+ keeps the longest `limit` imports (default 0: none); 3.2 lists all.
      const durations = config.experimental?.importDurations;
      if (durations) durations.limit = Number.POSITIVE_INFINITY;
    }
    // The marker runs from a copy under the root's node_modules: vite loads no setup file
    // from outside the workspace, and a checkout's helpers may link to one elsewhere (Node
    // gives this module its real path). Written only when it differs: the tests read it, so
    // a rewrite in every run changed a file the last run's footprints hold as they ran.
    const marker = path.join(vitest.config.root, 'node_modules', '.enact', 'vitest-marker.mjs');
    const source = fs.readFileSync(MARKER_SOURCE);
    let copy = null;
    try {
      copy = fs.readFileSync(marker);
    } catch {}
    if (!copy || !copy.equals(source)) {
      fs.mkdirSync(path.dirname(marker), { recursive: true });
      fs.writeFileSync(marker, source);
    }
    for (const project of projects) {
      const setupFiles = project.config.setupFiles;
      if (Array.isArray(setupFiles) && !setupFiles.includes(marker)) setupFiles.unshift(marker);
    }
  }

  write(entry) {
    if (OUT) fs.appendFileSync(OUT, `${JSON.stringify(entry)}\n`);
  }

  onTestModuleEnd(testModule) {
    const target = testModule.moduleId;
    const config = testModule.project.config;
    const durations = testModule.diagnostic?.().importDurations;
    const ids = durations ? Object.keys(durations) : [];
    const reads = [...new Set(ids.map(modulePath).filter(Boolean))];
    const limit = config.experimental?.importDurations?.limit ?? Number.POSITIVE_INFINITY;
    const whole =
      durations !== undefined && ids.length < limit && reads.includes(target) && forkPerFile(config);
    const state = testModule.state();
    let outcome = state === 'passed' || state === 'skipped' ? state : 'failed';
    if (!whole && outcome !== 'failed') outcome = 'partial';
    this.write({ target, outcome, skipped: skippedSome(testModule), reads });
  }

  onTestRunEnd(testModules, unhandledErrors = []) {
    for (const error of unhandledErrors) {
      const file = error?.VITEST_TEST_PATH;
      if (file) {
        this.write({ target: file, outcome: 'failed', reads: [] });
      } else {
        for (const testModule of testModules) {
          this.write({ target: testModule.moduleId, outcome: 'failed', reads: [] });
        }
      }
    }
  }
}

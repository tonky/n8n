// =============================================================================================
// vitest-marker.mjs - Marks the test file a vitest worker runs for enact's tracer and recorder
// =============================================================================================
// The first setup file of a traced run (vitest-attribution.mjs adds it). Opening
// `/__enact_marker__/START:<test file>` is intercepted by `enact trace run`'s tracer like any
// open, so it is ordered before the worker's later reads: those, and the reads of the
// processes the worker starts, go to the test file. Untraced, the open just fails.
// Under `--node-functions` the recorder enact preloads (`globalThis[Symbol.for('enact.node')]`)
// is told the file too, so the functions the worker runs from here on are its; the worker's
// start-up before this is every file's (setup reaches every test). The file's last hook
// ends the target: the recorder writes then, not only when vitest SIGTERMs the fork (and
// SIGKILLs it 500 ms later), which may cut a slow write short.
// Imports no 'vitest': a checkout can hold several (vitest 3.2 to 5), and the worker's own
// API is `globalThis.__vitest_index__`.
import fs from 'node:fs';
import mod from 'node:module';

const worker = globalThis.__vitest_worker__;
const file = worker?.filepath;
const fifo = process.env.ENACT_TRACE_FIFO;
if (file) {
  try {
    fs.closeSync(fs.openSync(`/__enact_marker__/START:${file}`, 'r'));
  } catch {
    // No such path: the tracer saw the open, or no tracer runs.
  }
  const recorder = globalThis[Symbol.for('enact.node')];
  if (recorder) {
    recorder.target(file);
  } else if (fifo) {
    try {
      fs.appendFileSync(
        fifo,
        `${JSON.stringify({ type: 'marker', event: 'start', pid: process.pid, target: file })}\n`,
      );
    } catch {}
  }
  const task = worker.current?.file ?? worker.current;
  const collectReads = () => {
    const executed = worker.moduleExecutionInfo ? worker.moduleExecutionInfo.keys() : [];
    const evaluated = worker.evaluatedModules?.idToModuleMap
      ? [...worker.evaluatedModules.idToModuleMap.values()].map((m) => m.file || m.id)
      : [];
    const cached = Object.keys(mod._cache ?? {}).filter((id) => !id.includes('/node_modules/'));
    const compiled = recorder?.files?.() ?? [];
    return [...new Set([...executed, ...evaluated, ...cached, ...compiled].filter(Boolean))];
  };
  if (task?.meta) {
    Object.defineProperty(task.meta, 'enactReads', {
      get: collectReads,
      enumerable: true,
      configurable: true,
    });
  }
  // A cleanup beforeAll returns runs after the file's every afterAll: after this
  // first setup file's hooks, last ('stack' order), before vitest sends suite.meta.
  globalThis.__vitest_index__?.beforeAll?.(() => () => {
    const meta = (task ?? worker.current?.file ?? worker.current)?.meta;
    if (meta) {
      Object.defineProperty(meta, 'enactReads', {
        value: collectReads(),
        enumerable: true,
        configurable: true,
        writable: true,
      });
    }
    recorder?.end();
    if (fifo) {
      try {
        fs.appendFileSync(
          fifo,
          `${JSON.stringify({ type: 'marker', event: 'end', pid: process.pid, target: file })}\n`,
        );
      } catch {}
    }
  });
}

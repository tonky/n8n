package schema

// Target file matching and empty set evaluation filter. `include` and `exclude` are
// path patterns (see #WorkspaceScope for the rule), anchored at the repository root:
// "*.json" is the root's JSON files, "**/*.json" every one. `on_empty`: when it matches
// none of the component's changed files the task is skipped (a job whose every task
// skipped ran nothing and ends skipped), passes (`pass`: the job passes), fails, or runs
// on all of them (`run_all`). The filter judges only the component's own changes: when
// anything else reaches the job (`--all`, `--updated`, a dependency's change, an unmapped
// file, a file its tests read, outputs it builds) the task runs.
#FileFilter: {
	include: [...string]
	exclude?: [...string]
	on_empty: *#EmptyPolicy.Skip | #EmptyPolicyMode
}

// One command a job runs
#Task: {
	name?: string
	// e.g. "python tools/snob.py {changed_files}" or "go list -test {changed_files}".
	// Required and non-empty: enact runs no default command in its place.
	command: string
	shell?:  #ShellMode
	env?: [string]: string
	// Variables removed from the task's environment, e.g. the injected service
	// connection variables for a task that runs against its own throwaway database.
	unset_env?: [...string]
	// e.g. "10m"
	timeout?: #Duration
	filter?:  #FileFilter
	caches?: [...#Cache]
	// Exit codes meaning the command broke rather than its tests failed (pytest's
	// 2/3/4: interrupted, internal or usage error). Such an exit stops the whole run at
	// once, naming it; any other non-zero exit is a test failure.
	error_exit_codes?: [...int]
}

// Declarative test target selector specification
#SelectorSpec: {
	// Command that accepts changed files and outputs resolved test targets
	command:   string
	fallback?: #SelectorFallbackMode | *#SelectorFallback.All
	timeout?:  int | *10
	// "file" collapses path::Class::test targets to their file so shards run whole
	// files in their own order (pytest-split parity); "item" keeps them as selected.
	granularity?: #TargetGranularityMode | *#TargetGranularity.Item
	// Size shards to the selected targets
	adaptive_shards?: bool | *true
}

// Multi-level test and blast radius scoping specification
#ScopingRules: {
	// e.g. #ScopingSelector.PythonSnob or custom selector
	selector?: #ScopingSelectorMode | #SelectorSpec | string
	// Directories the component's sparse cone adds, as path patterns
	domain_roots?: [...string]
	// Regex patterns in tests requiring running microservices
	service_markers?: [...string]
}

package suite

// --- ANSI --------------------------------------------------------------------

RESET  :: "\x1b[0m"
BOLD   :: "\x1b[1m"
DIM    :: "\x1b[2m"
RED    :: "\x1b[31m"
GREEN  :: "\x1b[32m"
YELLOW :: "\x1b[33m"
BLUE   :: "\x1b[34m"

LOG_FILE_NAME    :: ".zs.log"
STAMPS_FILE_NAME :: ".zs.stamps"
SUITE_CONFIG     :: ".zs.config"

// --- Config types ------------------------------------------------------------

EntryKind :: enum u8 { Check, Test, Build, Shared }

SuiteEntry :: struct {
	kind:     EntryKind,
	path:     string,   // relative to root
	name:     string,   // last path component, for display
	nostrict: bool,     // skip -strict-style -vet when checking
	is_main:  bool,     // true if this is the main entry (declared via main:)
}

CollectionDecl :: struct {
	name: string,
	path: string, // relative to root
}

// --- Runtime types -----------------------------------------------------------

TaskState :: enum u8 { Pending, Running, Passed, Failed, Skipped }

// Step is a single runnable phase: check, test, or build.
Step :: enum u8 { Check, Test, Build }

// SuitePlan holds the ordered list of steps to run per entry.
// step_count <= 3; steps[0..step_count] are valid.
SuitePlan :: struct {
	steps:      [3]Step,
	step_count: int,
}

plan_has_step :: #force_inline proc(plan: SuitePlan, s: Step) -> bool {
	for i in 0..<plan.step_count {
		if plan.steps[i] == s { return true }
	}
	return false
}

TestResult :: struct {
	path:         string,
	output:       string,
	passed:       bool,
	total_tests:  int,
	failed_tests: int,
}

CheckResult :: struct {
	path:   string,
	output: string,
	passed: bool,
}

// --- Unified display row (one row per entry; all three step states inline) ------

TableRow :: struct {
	suite:        string,
	check_state: TaskState,
	check_info:  string,
	test_state:  TaskState,
	test_info:   string,
	build_state: TaskState,
	build_info:  string,
	errors:      string,
}

// --- Worker types ------------------------------------------------------------

EntryResult :: struct {
	status:       TaskState,
	detail:       string,
	log_output:   string,
	update_stamp: bool,   // true if all steps passed, stamp should be saved
	stamp_key:    string, // entry path
	stamp_hash:   string, // hash of entry + collections
}

EntryWorkerData :: struct {
	idx:              int,
	entries:          []SuiteEntry,
	results:          ^[]EntryResult,
	root_dir:         string,
	collections:      []CollectionDecl,
	plan:             SuitePlan,
	debug_build:      bool,
	current_hash:     string,             // precomputed hash of entry + collections
	table_rows:       ^[dynamic]TableRow, // global display rows; nil = display disabled
	table_rows_start: int,                // index of this entry's first row
	done_flag:        ^bool,              // set true when this entry finishes
}

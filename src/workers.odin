package suite

import "core:fmt"
import "core:path/filepath"
import "core:strings"
import "core:thread"

// count_check_errors counts compiler "Error:" lines in odin check output.
count_check_errors :: proc(output: string) -> int {
	n := 0
	for line in strings.split_lines(output) {
		if strings.contains(line, " Error:") || strings.has_prefix(line, "Error:") {
			n += 1
		}
	}
	return max(n, 1)
}

// ── table-row helpers (nil-safe, operate on the single row per entry) ───────────

@(private="file")
tr_row :: #force_inline proc(data: ^EntryWorkerData) -> ^TableRow {
	if data.table_rows == nil { return nil }
	return &data.table_rows^[data.table_rows_start]
}

@(private="file")
tr_set_state :: #force_inline proc(row: ^TableRow, step: Step, state: TaskState) {
	switch step {
	case .Check: row.check_state = state
	case .Test:  row.test_state  = state
	case .Build: row.build_state = state
	}
}

@(private="file")
tr_set_info :: #force_inline proc(row: ^TableRow, step: Step, info: string) {
	switch step {
	case .Check: row.check_info = info
	case .Test:  row.test_info  = info
	case .Build: row.build_info = info
	}
}

@(private="file")
tr_running :: #force_inline proc(data: ^EntryWorkerData, step: Step) {
	row := tr_row(data); if row == nil { return }
	tr_set_state(row, step, .Running)
}

@(private="file")
tr_pass :: #force_inline proc(data: ^EntryWorkerData, step: Step, info: string) {
	row := tr_row(data); if row == nil { return }
	tr_set_state(row, step, .Passed)
	tr_set_info(row, step, info)
}

@(private="file")
tr_skip :: #force_inline proc(data: ^EntryWorkerData, step: Step) {
	row := tr_row(data); if row == nil { return }
	tr_set_state(row, step, .Skipped)
}

// tr_fail marks the given step as Failed, skips remaining plan steps, stores errors,
// and signals the worker as done.
@(private="file")
tr_fail :: proc(data: ^EntryWorkerData, step: Step, info: string, errors: string) {
	row := tr_row(data)
	if row != nil {
		tr_set_state(row, step, .Failed)
		tr_set_info(row, step, info)
		row.errors = errors
		// mark all later plan steps as Skipped
		found := false
		for s in 0..<data.plan.step_count {
			if data.plan.steps[s] == step { found = true; continue }
			if found { tr_set_state(row, data.plan.steps[s], .Skipped) }
		}
	}
	if data.done_flag != nil { data.done_flag^ = true }
}

@(private="file")
tr_done :: #force_inline proc(data: ^EntryWorkerData) {
	if data.done_flag != nil { data.done_flag^ = true }
}

// ── sub-log helpers (for sub-package tests with is_sub=true) ─────────────────

@(private="file")
sl_running :: #force_inline proc(data: ^EntryWorkerData) {
	if data.sub_log_entry == nil { return }
	data.sub_log_entry.state = .Running
}

@(private="file")
sl_pass :: #force_inline proc(data: ^EntryWorkerData, total_tests: int) {
	if data.sub_log_entry == nil { return }
	data.sub_log_entry.state       = .Passed
	data.sub_log_entry.total_tests = total_tests
	data.sub_log_entry.error_count = 0
}

@(private="file")
sl_fail :: #force_inline proc(data: ^EntryWorkerData, error_count: int, total_tests: int) {
	if data.sub_log_entry == nil { return }
	data.sub_log_entry.state       = .Failed
	data.sub_log_entry.error_count = error_count
	data.sub_log_entry.total_tests = total_tests
}

// run_entry_worker processes one SuiteEntry running plan.steps in declared order.
// Results are written to data.results^[data.idx]; no shared mutex needed.
run_entry_worker :: proc(t: ^thread.Thread) {
	data  := (^EntryWorkerData)(t.data)
	entry := data.entries[data.idx]
	plan  := data.plan

	log := strings.builder_make()

	result := EntryResult{
		status       = .Failed,
		detail       = "failed",
		update_stamp = false,
		stamp_key    = strings.clone(entry.path),
		stamp_hash   = strings.clone(data.current_hash),
	}

	sl_running(data)

	for i in 0..<plan.step_count {
		step      := plan.steps[i]
		remaining := plan.step_count - i - 1

		tr_running(data, step)

		switch step {

		// ── Check ──────────────────────────────────────────────────────────
		case .Check:
			cr := run_entry_check(data.root_dir, entry.path, data.collections, entry.kind, entry.nostrict)
			if !cr.passed {
				n_err    := count_check_errors(cr.output)
				err_info := fmt.aprintf("%d error%s", n_err, "s" if n_err != 1 else "") if n_err > 0 else "failed"
				suffix   := "; remaining steps skipped" if remaining > 0 else ""
				fmt.sbprintf(&log, "fail %s: check failed%s\n%s\n", entry.name, suffix, cr.output)
				result.status      = .Failed
				result.detail      = "check failed"
				result.log_output  = strings.clone(strings.to_string(log))
				result.error_count = n_err
				result.total_tests = 0
				strings.builder_destroy(&log)
				data.results^[data.idx] = result
				tr_fail(data, .Check, err_info, strings.clone(cr.output))
				sl_fail(data, n_err, 0)
				delete(cr.output)
				return
			}
			tr_pass(data, .Check, "")
			fmt.sbprintf(&log, "ok %s: check\n", entry.name)
			delete(cr.output)

		// ── Test ───────────────────────────────────────────────────────────
		case .Test:
			tr := run_entry_test(data.root_dir, entry.path, data.collections)
			if !tr.passed {
				passed_count := tr.total_tests - tr.failed_tests
				test_info    := fmt.aprintf("[%d/%d]", passed_count, tr.total_tests) if tr.total_tests > 0 else "failed"
				suffix       := "; remaining steps skipped" if remaining > 0 else ""
				fmt.sbprintf(&log, "fail %s: tests failed%s\n%s\n", entry.name, suffix, tr.output)
				result.status      = .Failed
				result.detail      = "tests failed"
				result.log_output  = strings.clone(strings.to_string(log))
				result.error_count = tr.failed_tests
				result.total_tests = tr.total_tests
				strings.builder_destroy(&log)
				data.results^[data.idx] = result
				tr_fail(data, .Test, test_info, strings.clone(tr.output))
				sl_fail(data, tr.failed_tests, tr.total_tests)
				delete(tr.output)
				return
			}
			tr_pass(data, .Test, fmt.aprintf("[%d/%d]", tr.total_tests, tr.total_tests))
			sl_pass(data, tr.total_tests)
			fmt.sbprintf(&log, "ok %s: test\n", entry.name)
			delete(tr.output)

		// ── Build ──────────────────────────────────────────────────────────
		case .Build:
			build_ok  := false
			build_out := ""
			switch entry.kind {
			case .Build:
				// bin dir = one level above the package entry point.
				bin_dir := filepath.join({data.root_dir, filepath.dir(entry.path), "bin"})
				build_ok, build_out = run_entry_build(data.root_dir, bin_dir, entry.path, entry.name, data.collections, data.debug_build)
				delete(bin_dir)
			case .Shared:
				out_dir := filepath.join({data.root_dir, entry.path, "bin"})
				build_ok, build_out = run_entry_shared(data.root_dir, out_dir, entry.path, entry.name, data.collections, data.debug_build)
				delete(out_dir)
			case .Check, .Test:
				// check/test-only entries: no build step
				tr_skip(data, .Build)
				continue
			}
			if !build_ok {
				fmt.sbprintf(&log, "fail %s: build failed\n%s\n", entry.name, build_out)
				result.status     = .Failed
				result.detail     = "build failed"
				result.log_output = strings.clone(strings.to_string(log))
				strings.builder_destroy(&log)
				data.results^[data.idx] = result
				tr_fail(data, .Build, "aborted", strings.clone(build_out))
				delete(build_out)
				return
			}
			delete(build_out)

			tr_pass(data, .Build, "")
			fmt.sbprintf(&log, "ok %s: build\n", entry.name)
			fmt.sbprintf(&log, "complete %s\n", entry.name)
			result.status       = .Passed
			result.detail       = "built"
			result.update_stamp = true
			result.log_output   = strings.clone(strings.to_string(log))
			strings.builder_destroy(&log)
			data.results^[data.idx] = result
			tr_done(data)
			return
		}
	}

	// ── All steps passed (no build step) ─────────────────────────────────────
	fmt.sbprintf(&log, "complete %s\n", entry.name)
	result.status       = .Passed
	result.detail       = "ok"
	result.update_stamp = true
	result.log_output   = strings.clone(strings.to_string(log))
	strings.builder_destroy(&log)
	data.results^[data.idx] = result
	tr_done(data)
}


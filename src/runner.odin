package suite

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:thread"
import "core:time"

run_incremental_suite :: proc(root_dir: string, config_file: string, include_patterns: [dynamic]string, exclude_patterns: [dynamic]string, plan: SuitePlan, debug_build: bool, force_build: bool) {
	exe_path       := os.args[0]
	exe_dir        := filepath.dir(exe_path)
	clean_root_dir := filepath.clean(root_dir)
	defer delete(clean_root_dir)
	log_path    := filepath.join({exe_dir, LOG_FILE_NAME})
	stamps_path := filepath.join({exe_dir, STAMPS_FILE_NAME})

	os.write_entire_file(log_path, []u8{})

	stamps := load_stamps(stamps_path)
	b      := strings.builder_make()

	// ── Load config ────────────────────────────────────────────────────────────
	all_entries, collections, config_ok := load_suite_config(clean_root_dir, config_file)
	if !config_ok {
		config_display := config_file if len(config_file) > 0 else SUITE_CONFIG
		fmt.sbprintf(&b, "fail: could not read %s in %s\n", config_display, clean_root_dir)
		log := strings.clone(strings.to_string(b))
		os.write_entire_file(log_path, transmute([]u8)log)
		delete(log)
		suite_exit(1)
	}
	defer {
		for e in all_entries { delete(e.path); delete(e.name) }
		delete(all_entries)
		for c in collections { delete(c.name); delete(c.path) }
		delete(collections)
	}

	has_includes := len(include_patterns) > 0

	// ── Filter entries ─────────────────────────────────────────────────────────
	filtered := make([dynamic]SuiteEntry)
	defer delete(filtered)
	for entry in all_entries {
		if has_includes && !matches_any_pattern(entry.name, include_patterns[:]) &&
		   !matches_any_pattern(entry.path, include_patterns[:]) { continue }
		if matches_any_pattern(filepath.base(entry.path), exclude_patterns[:]) { continue }
		append(&filtered, entry)
	}

	if len(filtered) == 0 {
		if has_includes {
			fmt.sbprintf(&b, "fail: no entries matched include filter\n")
			log := strings.clone(strings.to_string(b))
			os.write_entire_file(log_path, transmute([]u8)log)
			delete(log)
		} else if len(exclude_patterns) > 0 {
			fmt.eprintln("No packages found, skipping suite.")
			suite_exit(0)
		} else {
			fmt.sbprintf(&b, "fail: .zilo-suite has no entries\n")
			log := strings.clone(strings.to_string(b))
			os.write_entire_file(log_path, transmute([]u8)log)
			delete(log)
		}
		suite_exit(1)
	}

	// ── Stamp check + worker launch ────────────────────────────────────────────
	stale_indices      := make([dynamic]int)
	stale_table_starts := make([dynamic]int)
	stale_hashes       := make([dynamic]string)
	defer delete(stale_indices)
	defer delete(stale_table_starts)
	defer delete(stale_hashes)

	table_rows := make([dynamic]TableRow)
	failed_any := false

	for i in 0..<len(filtered) {
		entry := filtered[i]

		// Check if entry directory exists.
		entry_dir := filepath.join({clean_root_dir, entry.path})
		dir_exists := os.exists(entry_dir)
		delete(entry_dir)

		if !dir_exists {
			// Directory doesn't exist - mark as failed and continue.
			fmt.sbprintf(&b, "error %s: directory does not exist\n", entry.path)
			row := TableRow{suite = strings.clone(entry.name)}
			row.check_state = .Failed if plan_has_step(plan, .Check) else .Skipped
			row.check_info  = "missing"
			row.test_state  = .Skipped
			row.build_state = .Skipped
			row.errors      = strings.clone(fmt.tprintf("directory '%s' not found", entry.path))
			append(&table_rows, row)
			failed_any = true
			continue
		}

		// Compute hash including entry source + all collections.
		current_hash := hash_with_collections(clean_root_dir, entry.path, collections[:])

		// Check if stamp matches - if so, skip this entry entirely.
		stored_hash := stamps[entry.path] if entry.path in stamps else ""
		is_cached := !force_build && len(stored_hash) > 0 && stored_hash == current_hash

		// For build entries, also verify artifact exists.
		if is_cached && plan_has_step(plan, .Build) && (entry.kind == .Build || entry.kind == .Shared) {
			when ODIN_OS == .Windows { artifact_ext :: ".exe" } else { artifact_ext :: "" }
			artifact_path: string
			if entry.kind == .Shared {
				artifact_path = filepath.join({clean_root_dir, entry.path, "bin",
					strings.concatenate({entry.name, suite_lib_ext()})})
			} else {
				artifact_path = filepath.join({clean_root_dir, filepath.dir(entry.path), "bin",
					strings.concatenate({entry.name, artifact_ext})})
			}
			if !os.exists(artifact_path) {
				is_cached = false
				fmt.sbprintf(&b, "stale %s: artifact missing\n", entry.name)
			}
			delete(artifact_path)
		}

		if is_cached {
			// Entry unchanged - skip entirely and show as cached.
			row := TableRow{suite = strings.clone(entry.name)}
			row.check_state = .Passed if plan_has_step(plan, .Check) else .Skipped
			row.check_info  = "cached" if plan_has_step(plan, .Check) else ""
			row.test_state  = .Passed if plan_has_step(plan, .Test)  else .Skipped
			row.test_info   = "cached" if plan_has_step(plan, .Test)  else ""
			row.build_state = .Passed if plan_has_step(plan, .Build) else .Skipped
			row.build_info  = "cached" if plan_has_step(plan, .Build) else ""
			append(&table_rows, row)
			delete(current_hash)
			continue
		}

		// Entry needs work - add to stale list with Pending state.
		append(&stale_indices, i)
		append(&stale_table_starts, len(table_rows))
		append(&stale_hashes, current_hash)
		{
			row := TableRow{suite = strings.clone(entry.name)}
			row.check_state = .Pending if plan_has_step(plan, .Check) else .Skipped
			row.test_state  = .Pending if plan_has_step(plan, .Test)  else .Skipped
			row.build_state = .Pending if plan_has_step(plan, .Build) else .Skipped
			append(&table_rows, row)
		}
	}

	if len(stale_indices) > 0 {
		// Build a stale-only entries slice so worker idx maps 1-to-1 to results[idx].
		stale_entries := make([]SuiteEntry, len(stale_indices))
		defer delete(stale_entries)
		for j in 0..<len(stale_indices) {
			stale_entries[j] = filtered[stale_indices[j]]
		}

		worker_datas := make([]EntryWorkerData, len(stale_indices))
		results      := make([]EntryResult,    len(stale_indices))
		done_flags   := make([]bool,           len(stale_indices))
		threads      := make([dynamic]^thread.Thread)
		defer {
			delete(threads)
			delete(worker_datas)
			delete(done_flags)
		}

		for j in 0..<len(stale_indices) {
			worker_datas[j] = EntryWorkerData{
				idx              = j,
				entries          = stale_entries,
				results          = &results,
				root_dir         = clean_root_dir,
				collections      = collections[:],
				plan             = plan,
				debug_build      = debug_build,
				current_hash     = stale_hashes[j],
				table_rows       = &table_rows,
				table_rows_start = stale_table_starts[j],
				done_flag        = &done_flags[j],
			}

			t := thread.create(run_entry_worker)
			t.data = &worker_datas[j]
			thread.start(t)
			append(&threads, t)
		}

		// Live update loop: diff against previous snapshot, atomic os.write per tick.
		live_height := 0
		prev_snap   := make([]TableRow, len(table_rows))
		defer delete(prev_snap)

		fmt.printf("\x1b[?25l") // hide cursor
		for {
			all_done := true
			for j in 0..<len(stale_indices) {
				if !done_flags[j] { all_done = false; break }
			}
			prev := prev_snap[:] if live_height > 0 else nil
			live_height = print_table(table_rows[:], prev, true)
			copy(prev_snap, table_rows[:])
			if all_done { break }
			time.sleep(50 * time.Millisecond)
		}
		fmt.printf("\x1b[?25h") // restore cursor
		// Erase the live table before the final output.
		if live_height > 0 { fmt.printf("\x1b[%dA\x1b[0J", live_height) }

		for t in threads { thread.join(t); thread.destroy(t) }

		for j in 0..<len(stale_indices) {
			result := results[j]

			if result.status == .Failed { failed_any = true }
			// Save stamp if all steps passed.
			if result.update_stamp {
				stamps[strings.clone(result.stamp_key)] = strings.clone(result.stamp_hash)
			}
			delete(result.stamp_key)
			delete(result.stamp_hash)
			fmt.sbprintf(&b, "%s", result.log_output)
			delete(result.log_output)
		}
		delete(results)
	}

	save_stamps(stamps, stamps_path)

	if failed_any {
		fmt.sbprintf(&b, "suite: completed with failures\n")
	} else {
		fmt.sbprintf(&b, "suite: completed successfully\n")
	}

	print_table(table_rows[:], nil)
	delete(table_rows)

	log := strings.clone(strings.to_string(b))
	os.write_entire_file(log_path, transmute([]u8)log)
	delete(log)

	if failed_any { suite_exit(1) }
	suite_exit(0)
}

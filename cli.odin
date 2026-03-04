package suite

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

suite_usage :: proc() {
	fmt.println("usage: suite [flags]")
	fmt.println("")
	fmt.println("Incremental build, check, and test runner for Odin projects.")
	fmt.println("Reads a .suite config file from the project root.")
	fmt.println("")
	fmt.println("flags:")
	fmt.println("  -all                      check -> test -> build  (default)")
	fmt.println("  -check                    check only")
	fmt.println("  -test                     check -> test")
	fmt.println("  -debug                    pass -debug to odin build")
	fmt.println("  -f                        force: ignore cached stamps and rebuild everything")
	fmt.println("  -root=DIR                 project root directory (default: cwd)")
	fmt.println("  -config=FILE              config file path (default: <root>/.suite)")
	fmt.println("  -packages=FILTER          filter which packages to run")
	fmt.println("                            +name  include only entries matching name")
	fmt.println("                            -name  exclude entries matching name")
	fmt.println("                            comma-separated, mixed +/- allowed")
	fmt.println("                            omit or leave empty = all packages")
	fmt.println("  -help                     show this help")
	fmt.println("")
	fmt.println("examples:")
	fmt.println("  suite                               check -> test -> build (all)")
	fmt.println("  suite -check                        check only (all packages)")
	fmt.println("  suite -test                         check -> test (all packages)")
	fmt.println("  suite -all -debug                   full pipeline with debug symbols")
	fmt.println("  suite -f                            force rebuild everything")
	fmt.println("  suite -root=/path/to/project         run against a different directory")
	fmt.println("  suite -packages='+myapp'            only entries matching myapp")
	fmt.println("  suite -packages='-tests'            exclude entries matching tests")
	fmt.println("  suite -test -packages='+lib,+core'  test only lib and core")
}

parse_cli_args :: proc(args: []string) -> (plan: SuitePlan, include_patterns: [dynamic]string, exclude_patterns: [dynamic]string, root_dir: string, config_file: string, debug_build: bool, force_build: bool, show_help: bool, ok: bool) {
	plan             = SuitePlan{}
	include_patterns = make([dynamic]string)
	exclude_patterns = make([dynamic]string)
	root_dir         = ""
	config_file      = ""
	debug_build      = false
	force_build      = false
	show_help        = false

	got_mode := false

	for i := 0; i < len(args); i += 1 {
		arg := args[i]
		a := strings.trim_space(arg)
		if len(a) == 0 { continue }

		if a == "-help" {
			show_help = true
			continue
		}

		// ─── mode flags ───
		if a == "-all" {
			if got_mode { return plan, include_patterns, exclude_patterns, "", "", false, false, false, false }
			plan.steps[0] = .Check
			plan.steps[1] = .Test
			plan.steps[2] = .Build
			plan.step_count = 3
			got_mode = true
			continue
		}
		if a == "-check" {
			if got_mode { return plan, include_patterns, exclude_patterns, "", "", false, false, false, false }
			plan.steps[0] = .Check
			plan.step_count = 1
			got_mode = true
			continue
		}
		if a == "-test" {
			if got_mode { return plan, include_patterns, exclude_patterns, "", "", false, false, false, false }
			plan.steps[0] = .Check
			plan.steps[1] = .Test
			plan.step_count = 2
			got_mode = true
			continue
		}

		// ─── debug ───
		if a == "-debug" {
			debug_build = true
			continue
		}

		// ─── force ───
		if a == "-f" {
			force_build = true
			continue
		}

		// ─── root ───
		if strings.has_prefix(a, "-root=") {
			root_dir = strings.trim_space(a[len("-root="):])
			continue
		}

		// ─── config ───
		if strings.has_prefix(a, "-config=") {
			config_file = strings.trim_space(a[len("-config="):])
			continue
		}

		// ─── packages ───
		if strings.has_prefix(a, "-packages=") {
			raw := a[len("-packages="):]
			inc, exc, pok := parse_package_filter(raw)
			if !pok { return plan, include_patterns, exclude_patterns, "", "", false, false, false, false }
			for v in inc { append(&include_patterns, v) }
			for v in exc { append(&exclude_patterns, v) }
			delete(inc)
			delete(exc)
			continue
		}

		// ─── unknown ───
		return plan, include_patterns, exclude_patterns, "", "", false, false, false, false
	}

	if show_help {
		return plan, include_patterns, exclude_patterns, root_dir, config_file, debug_build, force_build, true, true
	}

	// default: -all
	if !got_mode {
		plan.steps[0] = .Check
		plan.steps[1] = .Test
		plan.steps[2] = .Build
		plan.step_count = 3
	}

	if len(root_dir) == 0 {
		root_dir, _ = filepath.abs(".")
		if len(root_dir) == 0 {
			root_dir = "."
		}
	} else {
		resolved, abs_ok := filepath.abs(root_dir)
		if abs_ok {
			root_dir = resolved
		}
	}

	return plan, include_patterns, exclude_patterns, root_dir, config_file, debug_build, force_build, false, true
}

// parse_package_filter parses the value of -packages=VALUE.
// Items must be prefixed with + (include) or - (exclude), comma-separated.
// Example: "+zilo,-buf" → include=[zilo], exclude=[buf]
// An empty value is valid and means all packages.
parse_package_filter :: proc(raw: string) -> (include: [dynamic]string, exclude: [dynamic]string, ok: bool) {
	include = make([dynamic]string)
	exclude = make([dynamic]string)

	v := strings.trim_space(raw)
	if (strings.has_prefix(v, "'") && strings.has_suffix(v, "'")) ||
	   (strings.has_prefix(v, "\"") && strings.has_suffix(v, "\"")) {
		v = strings.trim_space(v[1:len(v)-1])
	}
	if len(v) == 0 {
		return include, exclude, true
	}

	parts := strings.split(v, ",")
	defer delete(parts)
	for p in parts {
		t := strings.trim_space(p)
		if len(t) == 0 { continue }
		if strings.has_prefix(t, "+") {
			name := strings.trim_space(t[1:])
			if len(name) == 0 { return include, exclude, false }
			append(&include, strings.clone(name))
		} else if strings.has_prefix(t, "-") {
			name := strings.trim_space(t[1:])
			if len(name) == 0 { return include, exclude, false }
			append(&exclude, strings.clone(name))
		} else {
			return include, exclude, false
		}
	}
	return include, exclude, true
}

matches_any_pattern :: proc(name: string, patterns: []string) -> bool {
	name_l := strings.to_lower(name)
	defer delete(name_l)
	for pat in patterns {
		pat_l := strings.to_lower(strings.trim_space(pat))
		if len(pat_l) == 0 {
			delete(pat_l)
			continue
		}
		if strings.contains(name_l, pat_l) {
			delete(pat_l)
			return true
		}
		delete(pat_l)
	}
	return false
}

matches_any_exclude :: matches_any_pattern

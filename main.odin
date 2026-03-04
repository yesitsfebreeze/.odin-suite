package suite

import "core:os"

main :: proc() {
	plan, include_patterns, exclude_patterns, root_dir, config_file, debug_build, force_build, show_help, ok := parse_cli_args(os.args[1:])
	if show_help {
		suite_usage()
		return
	}
	if !ok {
		suite_usage()
		suite_exit(1)
	}
	run_incremental_suite(root_dir, config_file, include_patterns, exclude_patterns, plan, debug_build, force_build)
}

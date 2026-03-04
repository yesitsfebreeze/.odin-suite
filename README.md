# Zilo-Suite

Incremental build, check, and test runner for [Odin](https://odin-lang.org) projects.

Parallel workers, content-hash stamps, live ANSI table — one config file.

## Install

```sh
odin build . -out:zs
# move `zs` (or `zs.exe`) somewhere on your PATH
```

## Usage

Drop a `.zilo-suite` file in your project root, then run:

```
zs                               # check → test → build (all entries)
zs -check                        # check only
zs -test                         # check → test
zs -all -debug                   # check → test → build with -debug
zs -f                            # force: ignore cached stamps, rebuild everything
zs -packages='+myapp'            # only entries matching "myapp"
zs -packages='-tests'            # exclude entries matching "tests"
zs -test -packages='+lib,+core'  # test only lib and core
```

### Flags

| Flag                | Description                                       |
|---------------------|---------------------------------------------------|
| `-all`              | check → test → build (default)                    |
| `-check`            | check only                                        |
| `-test`             | check → test                                      |
| `-debug`            | pass `-debug` to `odin build`                     |
| `-f`                | force rebuild, ignore stamp cache                 |
| `-packages=FILTER`  | `+name` include, `-name` exclude, comma-separated |
| `-help`             | show help                                         |

## Config format

Create a `.zilo-suite` file in your project root:

```
# Comments start with #

# Declare collection search paths (passed as -collection:name=path to odin)
build_args: collection mylib=libs/mylib

# Build entries: runs check → test → build
# Produces a binary at <parent>/bin/<name>
entry: src/myapp

# Append "nostrict" to skip -strict-style -vet during check
entry: src/legacy nostrict

# Test-only entries: runs check → test (no build artifact)
test: libs/mylib
```

### Entry types

- **`entry:`** — full pipeline: check → test → build. Binary placed in `<parent>/bin/<name>`.
- **`test:`** — check + test only. No build artifact produced.

### Collections

```
build_args: collection <name>=<relative-path>
```

Generates `-collection:<name>="<absolute-path>"` flags for all odin commands.

### Auto-discovery

For each `entry:` path, suite recursively walks subdirectories. Any directory containing `@tests.odin` is automatically added as an implicit `test:` entry.

## How it works

1. Reads `.zilo-suite` from the working directory
2. Hashes all `.odin` files in each entry directory (FNV-64a)
3. Compares against stored stamps (`.zilo-suite-stamps` next to the binary)
4. Skips entries whose hash matches and artifact exists on disk
5. Runs stale entries in parallel threads: check → test → build
6. Displays a live ANSI table with per-entry status
7. Saves updated stamps on success

## Output

```
SUITE   | CHECK | TEST      | BUILD
--------|-------|-----------|------
myapp   | OK    | OK [3/3]  | OK
mylib   | OK    | OK [12/12]| ----
legacy  | FAIL  | ----      | ----

ERRORS

legacy | check | 1 | src/legacy/foo.odin(12:5) Error: undeclared name 'bar'
```

## License

MIT

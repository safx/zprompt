# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

zprompt is a compiled zsh prompt binary written in Zig 0.15.2. It replaces Starship by hardcoding all configuration into the source. No config file parsing — edit the source, rebuild, done.

The original Starship config it replicates is `starship.toml` (kept for reference).

## Build Commands

```sh
zig build                            # Debug build
zig build -Doptimize=ReleaseSmall    # Smallest binary (~120KB)
zig build -Doptimize=ReleaseFast     # Fastest binary (~145KB)
zig build run -- --exit-code=0 --duration=5000  # Build and run
```

Binary output: `zig-out/bin/zprompt`

## Testing

No test framework. Verify manually:

```sh
# In a git repo
./zig-out/bin/zprompt --exit-code=0 --duration=0 | cat -v

# In a non-git directory
cd /tmp && /path/to/zprompt --exit-code=1 --duration=65000 | cat -v

# Benchmark
hyperfine --warmup 5 './zig-out/bin/zprompt --exit-code=0'
```

## Architecture

All output assembly happens in `main.zig:main()` — it's the orchestrator:

1. Parse `--exit-code=N --duration=MS` args
2. `findGitRoot()` walks CWD upward looking for `.git/` (synchronous)
3. Spawn up to 5 worker threads (git_main, git_extras, python, node, aws_sso)
4. Wait on each thread's `std.Thread.ResetEvent` with a shared 800ms deadline
5. Assemble output segments into `std.io.Writer.Allocating`, write to stdout

### Thread worker pattern

Every worker follows the same shape:

```
pub fn fooWorker(ctx: *FooCtx) void {
    defer ctx.event.set();          // signal completion even on failure
    ctx.result = doFoo(ctx...);     // null = failed/skipped
}
```

The `doFoo` function returns `?ResultType`. All errors convert to `null` via `catch return null`. The output assembly in main.zig skips null results with `if (ctx.result) |r| ...`.

### Git info collection strategy

- **git_main_worker**: Runs `git status --porcelain=v2 --branch` — one subprocess yields branch, remote, ahead/behind, HEAD hash, and all file status counts. Then runs `git describe --tags --exact-match` for tag.
- **git_extras_worker**: Checks `.git/` state files (rebase-merge, MERGE_HEAD, etc.) via direct file reads. Runs `git diff --numstat HEAD` for metrics.

### Output format

Segments write directly to `*std.io.Writer`. ANSI codes are wrapped in `%{..%}` for zsh prompt width calculation (defined in `style.zig`). The segment order in main.zig matches the starship.toml `format` string exactly.

## Zig 0.15.2 API Notes

These are non-obvious APIs that differ from older Zig versions and online examples:

- **Output buffer**: `std.io.Writer.Allocating` (not `std.ArrayList(u8)` — that's unmanaged and its writer is deprecated)
- **stdout**: `std.fs.File{ .handle = std.posix.STDOUT_FILENO }` (not `std.io.getStdOut()`)
- **Subprocess**: `std.process.Child.run(.{ .allocator, .argv, .cwd, .max_output_bytes })` — default max is 50KB, git commands use 256KB
- **Tagged union access**: `result.term != .Exited or result.term.Exited != 0` — always check the tag before accessing the payload to avoid UB in release builds
- **build.zig**: Uses `b.createModule(.{ .root_source_file = b.path("src/main.zig") })` passed to `.root_module` (not the old `.root_source_file` directly on `addExecutable`)

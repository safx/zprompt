# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

zprompt is a compiled zsh prompt binary written in Zig 0.16.0. It replaces Starship by hardcoding all configuration into the source. No config file parsing — edit the source, rebuild, done.

The original Starship config it replicates is `starship.toml` (kept for reference).

## Build Commands

```sh
zig build                            # Debug build
zig build -Doptimize=ReleaseSmall    # Smallest binary (~200KB)
zig build -Doptimize=ReleaseFast     # Fastest binary (~255KB)
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

`main` takes `std.process.Init` (the 0.16 entry-point form); from it come the `Io` (a thread-pool-backed implementation whose spawned children inherit this process's environment), the `Environ.Map` for env lookups, and the CLI arg vector. All output assembly happens in `main.zig:main()` — it's the orchestrator:

1. Parse `--exit-code=N --duration=MS` args (from `init.minimal.args.vector`), plus `--deadline=MS` / `--no-deadline` (async prompt support)
2. `findGitRoot()` walks CWD upward looking for `.git/` (synchronous)
3. Spawn up to 5 workers via `io.async` (git_main, git_extras, python, node, aws_sso) — skipped entirely when `--deadline=0` (instant prompt: synchronous segments only)
4. Compute one absolute `Io.Timeout` deadline (default 800ms; `--deadline=` overrides, `--no-deadline` → `.none`) shared by every subprocess across all workers; `await` each future
5. Assemble output segments into `std.Io.Writer.Allocating`, write to stdout via `std.Io.File.stdout().writeStreamingAll(io, ...)`

The deadline is enforced per-subprocess (`RunOptions.timeout`), not by a separate wait loop: because all workers run concurrently and share one absolute deadline, wall-clock is bounded by the deadline yet returns early when git is fast. `smp_allocator` is used (threadsafe, no leak-tracking) rather than `init.gpa`, since the process leaks-and-exits by design.

### Worker pattern

Each worker is a plain function returning `?ResultType` (null = failed/skipped), spawned with `io.async(doFoo, .{args...})`; the `Future` carries the value back on `await`. No completion events — `await` synchronizes. All errors convert to `null` via `catch return null`. The assembly skips null results with `if (result) |r| ...`.

### Git info collection strategy

- **doGitMain**: Runs `git status --porcelain=v2 --branch` — one subprocess yields branch, remote, ahead/behind, HEAD hash, and all file status counts. Then runs `git tag --points-at HEAD` for tags (returns all tags, displays count + shortest name).
- **doGitExtras**: Checks `.git/` state files (rebase-merge, MERGE_HEAD, etc.) via direct file reads. Runs `git diff --numstat HEAD` for metrics.

### Output format

Segments write directly to `*std.Io.Writer`. ANSI codes are wrapped in `%{..%}` for zsh prompt width calculation (defined in `style.zig`). The segment order in main.zig matches the starship.toml `format` string exactly.

## Zig 0.16.0 API Notes

0.16 moved I/O, time, and process/filesystem access behind the `std.Io` interface. Non-obvious points that differ from 0.15 and from most online examples:

- **Entry point**: `pub fn main(init: std.process.Init) !void`. Use `init.io` (Io), `init.environ_map` (env lookups; `.get(key)`), `init.minimal.args.vector` (args). The runtime configures `init.io`'s child environment from the real process environ, so spawned commands inherit `PATH`/`HOME`.
- **Concurrency**: `std.Thread.ResetEvent`/`Mutex`/etc. are gone; use `io.async(fn, args)` → `Future`, then `future.await(io)`. `std.Thread` keeps only `spawn`/`join`/`detach`/`getCpuCount`.
- **Output buffer**: `std.Io.Writer.Allocating` (the `std.io` lowercase namespace no longer exists; it's `std.Io`). `.init`/`.writer`/`.toArrayList`/`.deinit` unchanged.
- **stdout**: `std.Io.File.stdout().writeStreamingAll(io, bytes)` (no more `std.fs.File{ .handle = ... }`).
- **Subprocess**: `std.process.run(gpa, io, .{ .argv, .cwd = .{ .path = ... }, .stdout_limit = .limited(N), .timeout })` replaces `Child.run`. `RunResult.term` is now lowercase: `result.term != .exited or result.term.exited != 0`.
- **Filesystem**: `std.fs` is gutted (only `std.fs.path` remains). Use `std.Io.Dir.cwd()` then `.openDir(io, ...)`, `.access(io, sub, .{ .write = true })`, `.readFileAlloc(io, sub, gpa, .limited(N))`, `.statFile(io, sub, .{})` (mtime is `Io.Timestamp`, compare `.nanoseconds`), `.iterate()` + `.next(io)`, `.close(io)`.
- **Time**: `std.time` has only constants; wall clock is `std.Io.Timestamp.now(io, .real).toSeconds()`.
- **Timeout**: build `Io.Timeout{ .duration = .{ .raw = .{ .nanoseconds = ms * ns_per_ms }, .clock = .awake } }`, then `.toDeadline(io)` to pin an absolute deadline shareable across calls.
- **build.zig**: unchanged from 0.15 — `b.createModule(.{ .root_source_file = ... })` passed to `.root_module`.

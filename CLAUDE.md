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
2. Pin one absolute `Io.Timeout` deadline (default 800ms; `--deadline=` overrides, `--no-deadline` → `.none`) that bounds the **whole** collection phase and is also passed to every subprocess
3. Spawn 5 workers into an `Io.Group` via `concurrent` (git, python, node, aws_sso, readonly) — skipped entirely when `--deadline=0` (instant prompt: synchronous segments only, plus a synchronous `findGitRoot`/readonly check for the directory segment). The git worker runs `findGitRoot()` itself — it walks the directory tree and can block forever on a dead network mount, so it must not run on the main task — then `doGitMain` here and `doGitExtras` on a second thread
4. Race the worker group against a sleeper pinned to the same deadline (`Io.Select` over `union(enum) { workers, deadline }`). Workers publish into `Slot`s (value + atomic ready flag), so main can safely read partial results. If the sleeper wins, main assembles from the ready slots, writes, and calls `std.process.exit(0)` — deliberately not `Group.cancel` (cancelation *waits* for each task, so a worker stuck in an uninterruptible filesystem call would block it forever) and not a normal return (the Io teardown would join the stuck threads)
5. Assemble output segments into `std.Io.Writer.Allocating`, write to stdout via `std.Io.File.stdout().writeStreamingAll(io, ...)`

The deadline is enforced at two layers: `RunOptions.timeout` kills overrunning subprocesses, and the Select race + process exit bounds the filesystem-only paths (findGitRoot, marker checks, aws cache scan) that take no timeout. Wall-clock is bounded by the deadline yet main returns early when the workers are fast. `smp_allocator` is used (threadsafe, no leak-tracking) rather than `init.gpa`, since the process leaks-and-exits by design.

### Worker pattern

Each worker is a plain function that computes `?ResultType` (null = failed/skipped) and publishes it into a `Slot` — value plus atomic `ready` flag (release on publish, acquire on read) — so main can read whatever is finished even while other workers are still running. Workers are spawned with `group.concurrent(...) catch group.async(...)`: `concurrent` guarantees a dedicated unit of concurrency (which the shared-deadline design assumes), `async` is the degraded fallback that may run inline. All errors convert to `null` via `catch return null`. The assembly skips unready/null slots with `if (slots.foo.get()) |r| ...`.

### Git info collection strategy

- **doGitMain**: Runs `git status --porcelain=v2 --branch` — one subprocess yields branch, remote, ahead/behind, HEAD hash, and all file status counts. Then runs `git tag --points-at HEAD` for tags (returns all tags, displays count + shortest name).
- **doGitExtras**: Checks `.git/` state files (rebase-merge, MERGE_HEAD, etc.) via direct file reads. Runs `git diff --numstat HEAD` for metrics.

### Output format

Segments write directly to `*std.Io.Writer`. ANSI codes are wrapped in `%{..%}` for zsh prompt width calculation (defined in `style.zig`). The segment order in main.zig matches the starship.toml `format` string exactly.

## Zig 0.16.0 API Notes

0.16 moved I/O, time, and process/filesystem access behind the `std.Io` interface. Non-obvious points that differ from 0.15 and from most online examples:

- **Entry point**: `pub fn main(init: std.process.Init) !void`. Use `init.io` (Io), `init.environ_map` (env lookups; `.get(key)`), `init.minimal.args.vector` (args). The runtime configures `init.io`'s child environment from the real process environ, so spawned commands inherit `PATH`/`HOME`.
- **Concurrency**: `std.Thread.ResetEvent`/`Mutex`/etc. are gone. `io.async(fn, args)` → `Future` + `future.await(io)`, but async **may run inline** (weaker guarantee); `io.concurrent` / `Group.concurrent` guarantee a dedicated unit of concurrency and fail with `error.ConcurrencyUnavailable` (single-threaded build, thread-spawn failure). `Io.Group` awaits/cancels tasks as a whole; `Io.Select(U)` races tasks and returns the first completion. Cancelation (`Future.cancel`, `Group.cancel`, `Select.cancelDiscard`) delivers `error.Canceled` at the task's next cancelation point and **waits** for it — a task blocked in an uninterruptible syscall blocks the cancel too. `Timeout.sleep(io)` is a cancelation point, so canceling a sleeper wakes it promptly.
- **Output buffer**: `std.Io.Writer.Allocating` (the `std.io` lowercase namespace no longer exists; it's `std.Io`). `.init`/`.writer`/`.toArrayList`/`.deinit` unchanged.
- **stdout**: `std.Io.File.stdout().writeStreamingAll(io, bytes)` (no more `std.fs.File{ .handle = ... }`).
- **Subprocess**: `std.process.run(gpa, io, .{ .argv, .cwd = .{ .path = ... }, .stdout_limit = .limited(N), .timeout })` replaces `Child.run`. `RunResult.term` is now lowercase: `result.term != .exited or result.term.exited != 0`.
- **Filesystem**: `std.fs` is gutted (only `std.fs.path` remains). Use `std.Io.Dir.cwd()` then `.openDir(io, ...)`, `.access(io, sub, .{ .write = true })`, `.readFileAlloc(io, sub, gpa, .limited(N))`, `.statFile(io, sub, .{})` (mtime is `Io.Timestamp`, compare `.nanoseconds`), `.iterate()` + `.next(io)`, `.close(io)`.
- **Time**: `std.time` has only constants; wall clock is `std.Io.Timestamp.now(io, .real).toSeconds()`.
- **Timeout**: build `Io.Timeout{ .duration = .{ .raw = .{ .nanoseconds = ms * ns_per_ms }, .clock = .awake } }`, then `.toDeadline(io)` to pin an absolute deadline shareable across calls.
- **build.zig**: unchanged from 0.15 — `b.createModule(.{ .root_source_file = ... })` passed to `.root_module`.

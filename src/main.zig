const std = @import("std");
const git = @import("git.zig");
const modules = @import("modules.zig");

const Io = std.Io;
const DEFAULT_TIMEOUT_MS: u64 = 800;

pub fn main(init: std.process.Init) !void {
    // zprompt is fire-and-forget: it allocates a handful of small buffers, writes
    // one prompt, and exits, letting the OS reclaim everything. `smp_allocator` is
    // threadsafe (workers allocate concurrently) and does not leak-track, so it
    // suits this better than the runtime's leak-checked `init.gpa`, which would
    // report the intentional never-frees on every Debug run.
    const allocator = std.heap.smp_allocator;
    const io = init.io;
    const env = init.environ_map; // read-only lookups from workers (no writes)

    // ── Parse CLI args ───────────────────────────────────────────
    var exit_code: u8 = 0;
    var duration_ms: u64 = 0;
    var timeout_ms: u64 = DEFAULT_TIMEOUT_MS;
    var deadline_zero = false; // --deadline=0: instant prompt, no workers
    var wait_all = false; // --no-deadline: wait for every worker, drop nothing
    for (init.minimal.args.vector, 0..) |arg_z, i| {
        if (i == 0) continue; // skip program name
        const arg = std.mem.span(arg_z);
        if (std.mem.startsWith(u8, arg, "--exit-code=")) {
            exit_code = std.fmt.parseInt(u8, arg["--exit-code=".len..], 10) catch 0;
        } else if (std.mem.startsWith(u8, arg, "--duration=")) {
            duration_ms = std.fmt.parseInt(u64, arg["--duration=".len..], 10) catch 0;
        } else if (std.mem.startsWith(u8, arg, "--deadline=")) {
            // override the shared worker deadline (ms). --deadline=0 = instant prompt.
            const ms = std.fmt.parseInt(u64, arg["--deadline=".len..], 10) catch DEFAULT_TIMEOUT_MS;
            timeout_ms = ms;
            deadline_zero = ms == 0;
        } else if (std.mem.eql(u8, arg, "--no-deadline")) {
            wait_all = true;
        }
    }

    // With --deadline=0 (and not --no-deadline) we skip the worker tasks entirely
    // and emit only the synchronous segments (time, directory, character,
    // duration). This is both the fastest path and race-free. The async setup
    // pairs this instant prompt with a background `--no-deadline` run whose full
    // result replaces it via `zle reset-prompt`.
    const spawn_workers = !deadline_zero or wait_all;

    // One absolute deadline shared by every git/version subprocess across both
    // workers, so all async work stops at the same wall-clock instant.
    // --no-deadline (`.none`) blocks until every worker finishes.
    var timeout: Io.Timeout = if (wait_all)
        .none
    else
        .{ .duration = .{
            .raw = .{ .nanoseconds = @as(i96, @intCast(timeout_ms)) * std.time.ns_per_ms },
            .clock = .awake,
        } };
    timeout = timeout.toDeadline(io); // pin to now+timeout; `.none` stays `.none`

    // ── Sync: CWD, git root ──────────────────────────────────────
    const cwd: []const u8 = std.process.currentPathAlloc(io, allocator) catch "/";
    const git_root = git.findGitRoot(allocator, io, cwd);

    // ── Spawn workers (async) and collect results ────────────────
    var git_main: ?git.GitMainResult = null;
    var git_extras: ?git.GitExtrasResult = null;
    var python: ?modules.PythonInfo = null;
    var node: ?modules.NodeInfo = null;
    var aws: ?[]const u8 = null;

    if (spawn_workers) {
        // Start every task before awaiting any, so they run concurrently on the
        // Io thread pool.
        var py_f = io.async(modules.doPython, .{ allocator, io, env, timeout });
        var node_f = io.async(modules.doNode, .{ allocator, io, timeout });
        var aws_f = io.async(modules.doAwsSso, .{ allocator, io, env });
        if (git_root) |root| {
            var gm_f = io.async(git.doGitMain, .{ allocator, io, root.repo_root, root.git_dir, timeout });
            var ge_f = io.async(git.doGitExtras, .{ allocator, io, root.git_dir, root.repo_root, timeout });
            git_main = gm_f.await(io);
            git_extras = ge_f.await(io);
        }
        python = py_f.await(io);
        node = node_f.await(io);
        aws = aws_f.await(io);
    }

    // ── Assemble output ──────────────────────────────────────────
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;

    // add_newline = true
    try w.writeAll("\n");

    // Line 1
    try modules.writeTime(w, io);
    try w.writeAll(" ");
    try modules.writeDirectory(w, io, env, cwd, if (git_root) |r| r.repo_root else null);

    if (git_root != null) {
        if (git_main) |main_result| {
            try git.writeGitCommit(w, main_result);
            try git.writeGitBranch(w, main_result);
            try git.writeGitStatus(w, main_result.status);
        }
        if (git_extras) |extras| {
            if (extras.state) |state| try git.writeGitState(w, state);
            if (extras.metrics) |metrics| try git.writeGitMetrics(w, metrics);
        }
    }

    if (aws) |remaining| try modules.writeAwsSso(w, remaining);
    if (python) |info| try modules.writePython(w, info);
    if (node) |info| try modules.writeNode(w, info);
    try modules.writeCmdDuration(w, duration_ms);

    // Line 2
    try w.writeAll("\n");
    try modules.writeCharacter(w, exit_code);

    // ── Write to stdout ──────────────────────────────────────────
    const list = aw.toArrayList();
    const stdout = std.Io.File.stdout();
    stdout.writeStreamingAll(io, list.items) catch {};
}

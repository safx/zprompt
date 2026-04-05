const std = @import("std");
const git = @import("git.zig");
const modules = @import("modules.zig");
const style = @import("style.zig");

const Allocator = std.mem.Allocator;
const TIMEOUT_NS: u64 = 800 * std.time.ns_per_ms;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // ── Parse CLI args ───────────────────────────────────────────
    var exit_code: u8 = 0;
    var duration_ms: u64 = 0;
    {
        var args = std.process.args();
        _ = args.next(); // skip program name
        while (args.next()) |arg| {
            if (std.mem.startsWith(u8, arg, "--exit-code=")) {
                exit_code = std.fmt.parseInt(u8, arg["--exit-code=".len..], 10) catch 0;
            } else if (std.mem.startsWith(u8, arg, "--duration=")) {
                duration_ms = std.fmt.parseInt(u64, arg["--duration=".len..], 10) catch 0;
            }
        }
    }

    // ── Sync: CWD, git root ──────────────────────────────────────
    const cwd = std.process.getCwdAlloc(allocator) catch "/";
    const git_root = git.findGitRoot(allocator, cwd);

    // ── Spawn worker threads ─────────────────────────────────────
    var git_main_ctx: git.GitMainCtx = undefined;
    var git_extras_ctx: git.GitExtrasCtx = undefined;
    var python_ctx = modules.PythonCtx{ .allocator = allocator };
    var node_ctx = modules.NodeCtx{ .allocator = allocator };
    var aws_ctx = modules.AwsSsoCtx{ .allocator = allocator };

    var threads: [5]?std.Thread = .{ null, null, null, null, null };

    if (git_root) |root| {
        git_main_ctx = .{ .allocator = allocator, .repo_root = root.repo_root, .git_dir = root.git_dir };
        git_extras_ctx = .{ .allocator = allocator, .git_dir = root.git_dir, .repo_root = root.repo_root };
        threads[0] = std.Thread.spawn(.{}, git.gitMainWorker, .{&git_main_ctx}) catch null;
        threads[1] = std.Thread.spawn(.{}, git.gitExtrasWorker, .{&git_extras_ctx}) catch null;
    }

    threads[2] = std.Thread.spawn(.{}, modules.pythonWorker, .{&python_ctx}) catch null;
    threads[3] = std.Thread.spawn(.{}, modules.nodeWorker, .{&node_ctx}) catch null;
    threads[4] = std.Thread.spawn(.{}, modules.awsSsoWorker, .{&aws_ctx}) catch null;

    // ── Wait with timeout ────────────────────────────────────────
    const start = std.time.nanoTimestamp();
    var events: [5]*std.Thread.ResetEvent = undefined;
    events[0] = if (git_root != null) &git_main_ctx.event else &python_ctx.event;
    events[1] = if (git_root != null) &git_extras_ctx.event else &python_ctx.event;
    events[2] = &python_ctx.event;
    events[3] = &node_ctx.event;
    events[4] = &aws_ctx.event;

    for (0..5) |i| {
        if (threads[i] == null) continue;
        const elapsed: u64 = @intCast(@max(0, std.time.nanoTimestamp() - start));
        const remaining = if (elapsed >= TIMEOUT_NS) 0 else TIMEOUT_NS - elapsed;
        events[i].timedWait(remaining) catch {};
    }

    for (&threads) |*t| {
        if (t.*) |thread| {
            thread.detach();
            t.* = null;
        }
    }

    // ── Assemble output ──────────────────────────────────────────
    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;

    // add_newline = true
    try w.writeAll("\n");

    // Line 1
    try modules.writeTime(w);
    try w.writeAll(" ");
    try modules.writeDirectory(w, cwd, if (git_root) |r| r.repo_root else null);

    if (git_root != null) {
        if (git_main_ctx.result) |main_result| {
            try git.writeGitCommit(w, main_result);
            try git.writeGitBranch(w, main_result);
            try git.writeGitStatus(w, main_result.status);
        }
        if (git_extras_ctx.result) |extras| {
            if (extras.state) |state| try git.writeGitState(w, state);
            if (extras.metrics) |metrics| try git.writeGitMetrics(w, metrics);
        }
    }

    if (aws_ctx.result) |remaining| try modules.writeAwsSso(w, remaining);
    if (python_ctx.result) |info| try modules.writePython(w, info);
    if (node_ctx.result) |info| try modules.writeNode(w, info);
    try modules.writeCmdDuration(w, duration_ms);

    // Line 2
    try w.writeAll("\n");
    try modules.writeCharacter(w, exit_code);

    // ── Write to stdout ──────────────────────────────────────────
    const list = aw.toArrayList();
    const stdout = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    stdout.writeAll(list.items) catch {};
}

const std = @import("std");
const git = @import("git.zig");
const modules = @import("modules.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const EnvMap = std.process.Environ.Map;
const DEFAULT_TIMEOUT_MS: u64 = 800;

/// One worker result, handed from a worker thread to main. The worker writes
/// `value` and then sets `ready` (release); main checks `ready` (acquire)
/// before touching `value`. On the deadline path main reads while workers may
/// still be running, so this protocol is what keeps the read race-free.
fn Slot(comptime T: type) type {
    return struct {
        value: ?T = null,
        ready: std.atomic.Value(bool) = .init(false),

        fn publish(slot: *@This(), value: ?T) void {
            slot.value = value;
            slot.ready.store(true, .release);
        }

        /// null = failed, skipped, or still running when the deadline hit.
        fn get(slot: *const @This()) ?T {
            if (!slot.ready.load(.acquire)) return null;
            return slot.value;
        }
    };
}

const Slots = struct {
    git_root: Slot(git.GitRoot) = .{},
    git_main: Slot(git.GitMainResult) = .{},
    git_extras: Slot(git.GitExtrasResult) = .{},
    python: Slot(modules.PythonInfo) = .{},
    node: Slot(modules.NodeInfo) = .{},
    aws: Slot([]const u8) = .{},
    cwd_readonly: Slot(bool) = .{},
};

const Race = union(enum) { workers: void, deadline: void };

fn gitWorker(allocator: Allocator, io: Io, cwd: []const u8, timeout: Io.Timeout, slots: *Slots) void {
    // findGitRoot walks the directory tree, which on a dead network mount can
    // block forever — that is why it lives here, under the deadline race,
    // rather than on the main task.
    const root = git.findGitRoot(allocator, io, cwd);
    slots.git_root.publish(root);
    const r = root orelse return;
    // doGitExtras moves to its own thread when one can be spawned; doGitMain
    // runs here either way, so a saturated system degrades to sequential
    // collection instead of dropping a segment.
    var extras_f: ?Io.Future(?git.GitExtrasResult) =
        io.concurrent(git.doGitExtras, .{ allocator, io, r.git_dir, r.repo_root, timeout }) catch null;
    slots.git_main.publish(git.doGitMain(allocator, io, r.repo_root, r.git_dir, timeout));
    slots.git_extras.publish(if (extras_f) |*f|
        f.await(io)
    else
        git.doGitExtras(allocator, io, r.git_dir, r.repo_root, timeout));
}

fn pythonWorker(allocator: Allocator, io: Io, env: *const EnvMap, timeout: Io.Timeout, slots: *Slots) void {
    slots.python.publish(modules.doPython(allocator, io, env, timeout));
}

fn nodeWorker(allocator: Allocator, io: Io, timeout: Io.Timeout, slots: *Slots) void {
    slots.node.publish(modules.doNode(allocator, io, timeout));
}

fn awsWorker(allocator: Allocator, io: Io, env: *const EnvMap, slots: *Slots) void {
    slots.aws.publish(modules.doAwsSso(allocator, io, env));
}

fn readonlyWorker(io: Io, slots: *Slots) void {
    slots.cwd_readonly.publish(modules.isCwdReadonly(io));
}

/// Spawns every worker and returns once all of them have published.
/// Raced against the deadline sleeper by `main`; called directly (no race)
/// for --no-deadline.
fn runWorkers(allocator: Allocator, io: Io, env: *const EnvMap, cwd: []const u8, timeout: Io.Timeout, slots: *Slots) void {
    var group: Io.Group = .init;
    spawnWorker(&group, io, gitWorker, .{ allocator, io, cwd, timeout, slots });
    spawnWorker(&group, io, pythonWorker, .{ allocator, io, env, timeout, slots });
    spawnWorker(&group, io, nodeWorker, .{ allocator, io, timeout, slots });
    spawnWorker(&group, io, awsWorker, .{ allocator, io, env, slots });
    spawnWorker(&group, io, readonlyWorker, .{ io, slots });
    group.await(io) catch {};
}

fn spawnWorker(group: *Io.Group, io: Io, function: anytype, args: anytype) void {
    // concurrent guarantees a dedicated unit of concurrency, which the shared
    // absolute deadline assumes (io.async may run inline, turning max-of-workers
    // wall-clock into sum-of-workers). If no thread can be spawned, async still
    // collects everything — possibly serially, but bounded by the race in main.
    group.concurrent(io, function, args) catch group.async(io, function, args);
}

fn sleepUntil(io: Io, timeout: Io.Timeout) void {
    timeout.sleep(io) catch {}; // Canceled: the workers finished first
}

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

    // One shared budget for the whole collection phase. --no-deadline (`.none`)
    // blocks until every worker finishes.
    var timeout: Io.Timeout = if (wait_all)
        .none
    else
        .{ .duration = .{
            .raw = .{ .nanoseconds = @as(i96, @intCast(timeout_ms)) * std.time.ns_per_ms },
            .clock = .awake,
        } };

    // ── Sync: CWD ────────────────────────────────────────────────
    const cwd: []const u8 = std.process.currentPathAlloc(io, allocator) catch "/";

    // ── Run workers, bounded by the deadline ─────────────────────
    var slots: Slots = .{};
    var deadline_hit = false;

    if (spawn_workers) {
        // Pin the deadline to one absolute instant shared by the race below and
        // by every subprocess. It bounds the *whole* collection phase —
        // findGitRoot, filesystem probes, git/version subprocesses — so the
        // prompt renders within the budget no matter what hangs. (`.none`
        // stays `.none`.)
        timeout = timeout.toDeadline(io);
        if (wait_all) {
            runWorkers(allocator, io, env, cwd, timeout, &slots);
        } else {
            // Race the workers against a sleeper pinned to the same deadline.
            // Subprocesses are already killed by their own timeout; the race
            // additionally covers the filesystem-only paths (findGitRoot,
            // marker checks, the aws cache scan), which take no timeout and
            // can block forever on a dead network mount.
            var race_buf: [2]Race = undefined;
            var sel = Io.Select(Race).init(io, &race_buf);
            const raced = raced: {
                sel.concurrent(.deadline, sleepUntil, .{ io, timeout }) catch break :raced false;
                sel.concurrent(.workers, runWorkers, .{ allocator, io, env, cwd, timeout, &slots }) catch break :raced false;
                break :raced true;
            };
            if (raced) {
                switch (sel.await() catch .deadline) {
                    // Workers done: wake the sleeper (sleep is a cancelation
                    // point, so this returns promptly) and clean up.
                    .workers => sel.cancelDiscard(),
                    // Deadline: don't cancel — cancelation *waits* for each
                    // task, and a worker stuck in an uninterruptible
                    // filesystem call would block that forever. Render what
                    // is ready; the process exit below reaps the stragglers.
                    .deadline => deadline_hit = true,
                }
            } else {
                // No unit of concurrency available (single-threaded build or
                // thread-spawn failure): no race is possible. Run inline and
                // rely on the per-subprocess timeouts alone.
                sel.cancelDiscard();
                runWorkers(allocator, io, env, cwd, timeout, &slots);
            }
        }
    } else {
        // Instant prompt: no workers, but the directory segment still wants
        // the repo root and the read-only marker; do both synchronously.
        slots.git_root.publish(git.findGitRoot(allocator, io, cwd));
        slots.cwd_readonly.publish(modules.isCwdReadonly(io));
    }

    const git_root = slots.git_root.get();

    // ── Assemble output ──────────────────────────────────────────
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;

    // add_newline = true
    try w.writeAll("\n");

    // Line 1
    try modules.writeTime(w, io);
    try w.writeAll(" ");
    try modules.writeDirectory(w, env, cwd, if (git_root) |r| r.repo_root else null, slots.cwd_readonly.get() orelse false);

    if (git_root != null) {
        if (slots.git_main.get()) |main_result| {
            try git.writeGitCommit(w, main_result);
            try git.writeGitBranch(w, main_result);
            try git.writeGitStatus(w, main_result.status);
        }
        if (slots.git_extras.get()) |extras| {
            if (extras.state) |state| try git.writeGitState(w, state);
            if (extras.metrics) |metrics| try git.writeGitMetrics(w, metrics);
        }
    }

    if (slots.aws.get()) |remaining| try modules.writeAwsSso(w, remaining);
    if (slots.python.get()) |info| try modules.writePython(w, info);
    if (slots.node.get()) |info| try modules.writeNode(w, info);
    try modules.writeCmdDuration(w, duration_ms);

    // Line 2
    try w.writeAll("\n");
    try modules.writeCharacter(w, exit_code);

    // ── Write to stdout ──────────────────────────────────────────
    const list = aw.toArrayList();
    const stdout = std.Io.File.stdout();
    stdout.writeStreamingAll(io, list.items) catch {};

    // Deadline path: workers may still be blocked in filesystem calls that
    // take no timeout. Exiting here is what actually bounds them — the same
    // role the pre-0.16 timedWait+detach loop played. The prompt is already
    // flushed; a normal return would instead hang in the Io teardown joining
    // the stuck threads.
    if (deadline_hit) std.process.exit(0);
}

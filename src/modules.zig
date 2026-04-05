const std = @import("std");
const style = @import("style.zig");

const Allocator = std.mem.Allocator;
const Writer = std.io.Writer;

// ── Data structures ──────────────────────────────────────────────

pub const PythonInfo = struct {
    version: []const u8,
    virtualenv: ?[]const u8,
};

pub const NodeInfo = struct {
    version: []const u8,
};

// ── Thread contexts ──────────────────────────────────────────────

pub const PythonCtx = struct {
    event: std.Thread.ResetEvent = .{},
    allocator: Allocator,
    result: ?PythonInfo = null,
};

pub const NodeCtx = struct {
    event: std.Thread.ResetEvent = .{},
    allocator: Allocator,
    result: ?NodeInfo = null,
};

pub const AwsSsoCtx = struct {
    event: std.Thread.ResetEvent = .{},
    allocator: Allocator,
    result: ?[]const u8 = null,
};

// ── Workers ──────────────────────────────────────────────────────

pub fn pythonWorker(ctx: *PythonCtx) void {
    defer ctx.event.set();
    ctx.result = doPython(ctx.allocator);
}

pub fn nodeWorker(ctx: *NodeCtx) void {
    defer ctx.event.set();
    ctx.result = doNode(ctx.allocator);
}

pub fn awsSsoWorker(ctx: *AwsSsoCtx) void {
    defer ctx.event.set();
    ctx.result = doAwsSso(ctx.allocator);
}

fn doPython(allocator: Allocator) ?PythonInfo {
    if (!hasAnyMarker(&.{
        "pyproject.toml", "requirements.txt", "setup.py",
        "setup.cfg",     ".python-version",  "Pipfile",
        "tox.ini",
    })) return null;

    const version = runVersionCmd(allocator, &.{ "python3", "--version" }, "Python ") orelse return null;

    var virtualenv: ?[]const u8 = null;
    if (std.posix.getenv("VIRTUAL_ENV")) |venv_path| {
        if (std.mem.lastIndexOfScalar(u8, venv_path, '/')) |idx| {
            virtualenv = allocator.dupe(u8, venv_path[idx + 1 ..]) catch null;
        } else {
            virtualenv = allocator.dupe(u8, venv_path) catch null;
        }
    }

    return PythonInfo{ .version = version, .virtualenv = virtualenv };
}

fn doNode(allocator: Allocator) ?NodeInfo {
    if (!hasAnyMarker(&.{ "package.json", ".node-version", ".nvmrc" })) return null;
    const version = runVersionCmd(allocator, &.{ "node", "--version" }, "v") orelse return null;
    return NodeInfo{ .version = version };
}

fn hasAnyMarker(markers: []const []const u8) bool {
    for (markers) |m| {
        std.fs.cwd().access(m, .{}) catch continue;
        return true;
    }
    return false;
}

fn runVersionCmd(allocator: Allocator, argv: []const []const u8, prefix: []const u8) ?[]const u8 {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
    }) catch return null;
    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);
    if (result.term != .Exited or result.term.Exited != 0) return null;
    var out = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (prefix.len > 0 and std.mem.startsWith(u8, out, prefix)) out = out[prefix.len..];
    return allocator.dupe(u8, out) catch null;
}

fn doAwsSso(allocator: Allocator) ?[]const u8 {
    const home = std.posix.getenv("HOME") orelse return null;
    const cache_dir_path = std.fmt.allocPrint(allocator, "{s}/.aws/sso/cache", .{home}) catch return null;
    defer allocator.free(cache_dir_path);

    var cache_dir = std.fs.cwd().openDir(cache_dir_path, .{ .iterate = true }) catch return null;
    defer cache_dir.close();

    var newest_name: ?[]const u8 = null;
    var newest_mtime: i128 = 0;

    var iter = cache_dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        const stat = cache_dir.statFile(entry.name) catch continue;
        if (newest_name == null or stat.mtime > newest_mtime) {
            if (newest_name) |old| allocator.free(old);
            newest_name = allocator.dupe(u8, entry.name) catch continue;
            newest_mtime = stat.mtime;
        }
    }

    const name = newest_name orelse return null;
    defer allocator.free(name);

    const file_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ cache_dir_path, name }) catch return null;
    defer allocator.free(file_path);

    const content = std.fs.cwd().readFileAlloc(allocator, file_path, 64 * 1024) catch return null;
    defer allocator.free(content);

    const key = "\"expiresAt\"";
    const key_pos = std.mem.indexOf(u8, content, key) orelse return null;
    const after_key = content[key_pos + key.len ..];
    var i: usize = 0;
    while (i < after_key.len and (after_key[i] == ' ' or after_key[i] == ':' or after_key[i] == '"')) : (i += 1) {}
    const value_start = i;
    while (i < after_key.len and after_key[i] != '"') : (i += 1) {}
    if (i <= value_start) return null;
    const expires_str = after_key[value_start..i];

    const expires_epoch = parseIso8601(expires_str) orelse return null;
    const now = std.time.timestamp();
    const remaining = expires_epoch - now;
    if (remaining <= 0) return null;

    const remaining_u: u64 = @intCast(remaining);
    const hours = remaining_u / 3600;
    const minutes = (remaining_u % 3600) / 60;

    return std.fmt.allocPrint(allocator, "{d:0>2}:{d:0>2}", .{ hours, minutes }) catch null;
}

fn parseIso8601(s: []const u8) ?i64 {
    if (s.len < 19) return null;
    const year = std.fmt.parseInt(i64, s[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u32, s[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u32, s[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(u32, s[11..13], 10) catch return null;
    const minute = std.fmt.parseInt(u32, s[14..16], 10) catch return null;
    const second = std.fmt.parseInt(u32, s[17..19], 10) catch return null;

    var days: i64 = 0;
    var y: i64 = 1970;
    while (y < year) : (y += 1) {
        days += if (isLeapYear(y)) @as(i64, 366) else @as(i64, 365);
    }
    const month_days = [_]u32{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var m: u32 = 1;
    while (m < month) : (m += 1) {
        days += month_days[m - 1];
        if (m == 2 and isLeapYear(year)) days += 1;
    }
    days += @as(i64, day) - 1;

    return days * 86400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + @as(i64, second);
}

fn isLeapYear(y: i64) bool {
    const yu: u64 = @intCast(y);
    return (yu % 4 == 0 and yu % 100 != 0) or (yu % 400 == 0);
}

// ── Output writers ───────────────────────────────────────────────

pub fn writeTime(w: *Writer) !void {
    const ts = std.time.timestamp() + 9 * 3600;
    const day_seconds: u64 = @intCast(@mod(ts, 86400));
    const h = day_seconds / 3600;
    const m = (day_seconds % 3600) / 60;
    const s = day_seconds % 60;
    try w.print("{d:0>2}:{d:0>2}:{d:0>2}", .{ h, m, s });
}

pub fn writeDirectory(w: *Writer, cwd: []const u8, repo_root: ?[]const u8) !void {
    const home = std.posix.getenv("HOME") orelse "";

    if (repo_root) |root| {
        const repo_name_start = if (std.mem.lastIndexOfScalar(u8, root, '/')) |idx| idx + 1 else 0;
        const before_root_raw = root[0..repo_name_start];
        const repo_name = root[repo_name_start..];
        const inside = if (cwd.len > root.len) cwd[root.len..] else "";

        // Check if before_root_raw contains /.worktrees/ (worktree layout)
        // e.g. before_root_raw = "~/src/backlog/backlog-ai-agent/.worktrees/"
        //      repo_name = "b"
        // We want: gray(~/src/backlog/) white(backlog-ai-agent) gray(/.worktrees/) white(b)
        if (std.mem.indexOf(u8, before_root_raw, "/.worktrees/")) |wt_pos| {
            // Part before the parent repo name
            const parent_name_start = if (std.mem.lastIndexOfScalar(u8, before_root_raw[0..wt_pos], '/')) |idx| idx + 1 else 0;
            const prefix = before_root_raw[0..parent_name_start];
            const parent_name = before_root_raw[parent_name_start..wt_pos];
            const wt_suffix = before_root_raw[wt_pos..]; // "/.worktrees/"

            if (prefix.len > 0) {
                if (home.len > 0 and std.mem.startsWith(u8, prefix, home)) {
                    try w.writeAll(style.fg_666);
                    try w.writeAll("~");
                    try w.writeAll(truncatePath(prefix[home.len..], 10));
                    try w.writeAll(style.reset);
                } else {
                    try w.writeAll(style.fg_666);
                    try w.writeAll(truncatePath(prefix, 10));
                    try w.writeAll(style.reset);
                }
            }
            try style.styled(w, style.white, parent_name);
            try w.writeAll(style.fg_666);
            try w.writeAll(wt_suffix);
            try w.writeAll(style.reset);
        } else if (before_root_raw.len > 0) {
            if (home.len > 0 and std.mem.startsWith(u8, before_root_raw, home)) {
                try w.writeAll(style.fg_666);
                try w.writeAll("~");
                try w.writeAll(truncatePath(before_root_raw[home.len..], 10));
                try w.writeAll(style.reset);
            } else {
                try w.writeAll(style.fg_666);
                try w.writeAll(truncatePath(before_root_raw, 10));
                try w.writeAll(style.reset);
            }
        }

        try style.styled(w, style.white, repo_name);

        if (inside.len > 0) {
            try w.writeAll(style.green);
            try w.writeAll(inside);
            try w.writeAll(style.reset);
        }
    } else {
        if (home.len > 0 and std.mem.startsWith(u8, cwd, home)) {
            try w.writeAll(style.green);
            try w.writeAll("~");
            try w.writeAll(truncatePath(cwd[home.len..], 10));
            try w.writeAll(style.reset);
        } else {
            try style.styled(w, style.green, truncatePath(cwd, 10));
        }
    }

    std.fs.cwd().access(".", .{ .mode = .write_only }) catch {
        try w.writeAll(" \xf0\x9f\x94\x92"); // 🔒
        return;
    };
}

pub fn writeCmdDuration(w: *Writer, duration_ms: u64) !void {
    if (duration_ms < 30_000) return;

    const total_secs = duration_ms / 1000;
    try w.writeAll(" ");
    try w.writeAll(style.bold_yellow);
    try w.writeAll("\xe2\x8f\xb1"); // ⏱
    if (total_secs >= 3600) {
        try w.print("{d}h{d}m", .{ total_secs / 3600, (total_secs % 3600) / 60 });
    } else if (total_secs >= 60) {
        try w.print("{d}m{d}s", .{ total_secs / 60, total_secs % 60 });
    } else {
        try w.print("{d}s", .{total_secs});
    }
    try w.writeAll(style.reset);
}

pub fn writeCharacter(w: *Writer, exit_code: u8) !void {
    const color = if (exit_code == 0) style.green else style.red;
    try style.styled(w, color, "\xe2\x9d\xaf "); // ❯
}

pub fn writePython(w: *Writer, info: PythonInfo) !void {
    try w.writeAll(" ");
    try w.writeAll(style.yellow);
    try w.writeAll("py");
    try w.writeAll(info.version);
    if (info.virtualenv) |venv| {
        try w.writeAll("(@");
        try w.writeAll(venv);
        try w.writeAll(")");
    }
    try w.writeAll(style.reset);
}

pub fn writeNode(w: *Writer, info: NodeInfo) !void {
    try w.writeAll(" ");
    try w.writeAll(style.bright_green);
    try w.writeAll("js");
    try w.writeAll(info.version);
    try w.writeAll(style.reset);
}

pub fn writeAwsSso(w: *Writer, remaining: []const u8) !void {
    try w.writeAll(" ");
    try w.writeAll(style.cyan);
    try w.writeAll("\xf0\x9f\x85\xb0 "); // 🅰
    try w.writeAll(remaining);
    try w.writeAll(style.reset);
}

fn truncatePath(path: []const u8, max_components: usize) []const u8 {
    var count: usize = 0;
    var i: usize = path.len;
    while (i > 0) {
        i -= 1;
        if (path[i] == '/') {
            count += 1;
            if (count >= max_components) {
                return path[i..];
            }
        }
    }
    return path;
}

const std = @import("std");
const style = @import("style.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = std.Io.Writer;

// ── Data structures ──────────────────────────────────────────────

pub const GitMainResult = struct {
    branch: ?[]const u8 = null,
    remote: ?[]const u8 = null,
    hash: ?[7]u8 = null,
    tag: ?[]const u8 = null,
    tag_count: u32 = 0,
    status: GitStatus = .{},
};

pub const GitStatus = struct {
    conflicted: u32 = 0,
    deleted: u32 = 0,
    renamed: u32 = 0,
    modified: u32 = 0,
    untracked: u32 = 0,
    staged: u32 = 0,
    ahead: u32 = 0,
    behind: u32 = 0,
};

pub const GitState = struct {
    label: []const u8,
    progress_current: ?u32 = null,
    progress_total: ?u32 = null,
};

pub const GitMetrics = struct {
    added: u32 = 0,
    deleted: u32 = 0,
};

pub const GitExtrasResult = struct {
    state: ?GitState = null,
    metrics: ?GitMetrics = null,
};

// ── findGitRoot ──────────────────────────────────────────────────

pub const GitRoot = struct {
    repo_root: []const u8,
    git_dir: []const u8,
};

pub fn findGitRoot(allocator: Allocator, io: Io, cwd: []const u8) ?GitRoot {
    var path = allocator.dupe(u8, cwd) catch return null;
    while (true) {
        const git_path = std.fmt.allocPrint(allocator, "{s}/.git", .{path}) catch {
            allocator.free(path);
            return null;
        };

        if (isDir(io, git_path)) {
            return GitRoot{ .repo_root = path, .git_dir = git_path };
        }

        if (readSmallFile(allocator, io, git_path)) |content| {
            defer allocator.free(content);
            const trimmed = std.mem.trim(u8, content, " \t\r\n");
            if (std.mem.startsWith(u8, trimmed, "gitdir: ")) {
                const gitdir_ref = trimmed["gitdir: ".len..];
                const resolved = if (std.fs.path.isAbsolute(gitdir_ref))
                    allocator.dupe(u8, gitdir_ref) catch {
                        allocator.free(git_path);
                        allocator.free(path);
                        return null;
                    }
                else
                    std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, gitdir_ref }) catch {
                        allocator.free(git_path);
                        allocator.free(path);
                        return null;
                    };
                allocator.free(git_path);
                return GitRoot{ .repo_root = path, .git_dir = resolved };
            }
        }

        allocator.free(git_path);

        if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| {
            if (idx == 0) {
                allocator.free(path);
                return null;
            }
            const parent = allocator.dupe(u8, path[0..idx]) catch {
                allocator.free(path);
                return null;
            };
            allocator.free(path);
            path = parent;
        } else {
            allocator.free(path);
            return null;
        }
    }
}

// ── Workers ──────────────────────────────────────────────────────
//
// Run inside main's git worker task (spawned via `Io.Group.concurrent`); each
// returns its result directly (null = failed/skipped). `timeout` is a shared
// absolute deadline passed to every git subprocess, so all git work across
// both workers stops at the same wall-clock instant.

pub fn doGitMain(allocator: Allocator, io: Io, repo_root: []const u8, git_dir: []const u8, timeout: Io.Timeout) ?GitMainResult {
    _ = git_dir;
    var result = GitMainResult{};

    const status_out = runGit(allocator, io, repo_root, &.{ "git", "status", "--porcelain=v2", "--branch" }, timeout) orelse return null;
    defer allocator.free(status_out);

    var lines = std.mem.splitScalar(u8, status_out, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        if (std.mem.startsWith(u8, line, "# branch.oid ")) {
            const oid = line["# branch.oid ".len..];
            if (oid.len >= 7 and !std.mem.eql(u8, oid, "(initial)")) {
                result.hash = oid[0..7].*;
            }
        } else if (std.mem.startsWith(u8, line, "# branch.head ")) {
            const head = line["# branch.head ".len..];
            if (!std.mem.eql(u8, head, "(detached)")) {
                result.branch = allocator.dupe(u8, head) catch null;
            }
        } else if (std.mem.startsWith(u8, line, "# branch.upstream ")) {
            result.remote = allocator.dupe(u8, line["# branch.upstream ".len..]) catch null;
        } else if (std.mem.startsWith(u8, line, "# branch.ab ")) {
            parseAheadBehind(line["# branch.ab ".len..], &result.status);
        } else if (line[0] == '?') {
            result.status.untracked += 1;
        } else if (line[0] == 'u') {
            result.status.conflicted += 1;
        } else if (line[0] == '1' or line[0] == '2') {
            if (line.len >= 4) {
                parseXY(line[2], line[3], &result.status);
            }
        }
    }

    if (result.hash != null) {
        var tc: u32 = 0;
        result.tag = findPointsAtTags(allocator, io, repo_root, &tc, timeout);
        result.tag_count = tc;
    }

    return result;
}

pub fn doGitExtras(allocator: Allocator, io: Io, git_dir: []const u8, repo_root: []const u8, timeout: Io.Timeout) ?GitExtrasResult {
    var result = GitExtrasResult{};

    result.state = detectState(allocator, io, git_dir);

    const diff_out = runGit(allocator, io, repo_root, &.{ "git", "diff", "--numstat", "HEAD" }, timeout) orelse {
        const cached_out = runGit(allocator, io, repo_root, &.{ "git", "diff", "--numstat", "--cached" }, timeout) orelse return result;
        result.metrics = parseDiffNumstat(cached_out);
        allocator.free(cached_out);
        return result;
    };
    result.metrics = parseDiffNumstat(diff_out);
    allocator.free(diff_out);

    return result;
}

// ── Helpers ──────────────────────────────────────────────────────

fn parseAheadBehind(s: []const u8, status: *GitStatus) void {
    var parts = std.mem.splitScalar(u8, s, ' ');
    if (parts.next()) |ahead_str| {
        if (ahead_str.len > 1 and ahead_str[0] == '+') {
            status.ahead = std.fmt.parseInt(u32, ahead_str[1..], 10) catch 0;
        }
    }
    if (parts.next()) |behind_str| {
        if (behind_str.len > 1 and behind_str[0] == '-') {
            status.behind = std.fmt.parseInt(u32, behind_str[1..], 10) catch 0;
        }
    }
}

fn parseXY(x: u8, y: u8, status: *GitStatus) void {
    switch (x) {
        'A', 'M' => status.staged += 1,
        'D' => status.deleted += 1,
        'R' => status.renamed += 1,
        else => {},
    }
    switch (y) {
        'M' => status.modified += 1,
        'D' => status.deleted += 1,
        else => {},
    }
}

fn parseDiffNumstat(output: []const u8) ?GitMetrics {
    var metrics = GitMetrics{};
    var has_data = false;
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var cols = std.mem.splitScalar(u8, line, '\t');
        if (cols.next()) |added_str| {
            if (std.mem.eql(u8, added_str, "-")) continue;
            metrics.added += std.fmt.parseInt(u32, added_str, 10) catch continue;
            has_data = true;
        }
        if (cols.next()) |deleted_str| {
            if (std.mem.eql(u8, deleted_str, "-")) continue;
            metrics.deleted += std.fmt.parseInt(u32, deleted_str, 10) catch continue;
        }
    }
    return if (has_data or metrics.added > 0 or metrics.deleted > 0) metrics else null;
}

fn detectState(allocator: Allocator, io: Io, git_dir: []const u8) ?GitState {
    var dir = Io.Dir.cwd().openDir(io, git_dir, .{}) catch return null;
    defer dir.close(io);
    if (checkRebaseDir(allocator, io, dir, "rebase-merge", "msgnum", "end")) |s| return s;
    if (checkRebaseDir(allocator, io, dir, "rebase-apply", "next", "last")) |s| return s;
    if (dirHasFile(io, dir, "MERGE_HEAD")) return .{ .label = "MERGING" };
    if (dirHasFile(io, dir, "CHERRY_PICK_HEAD")) return .{ .label = "CHERRY-PICKING" };
    if (dirHasFile(io, dir, "REVERT_HEAD")) return .{ .label = "REVERTING" };
    if (dirHasFile(io, dir, "BISECT_LOG")) return .{ .label = "BISECTING" };
    return null;
}

fn checkRebaseDir(allocator: Allocator, io: Io, parent: Io.Dir, dir_name: []const u8, current_file: []const u8, total_file: []const u8) ?GitState {
    var sub = parent.openDir(io, dir_name, .{}) catch return null;
    defer sub.close(io);
    var state = GitState{ .label = "REBASING" };
    state.progress_current = readU32(allocator, io, sub, current_file);
    state.progress_total = readU32(allocator, io, sub, total_file);
    return state;
}

fn dirHasFile(io: Io, dir: Io.Dir, name: []const u8) bool {
    dir.access(io, name, .{}) catch return false;
    return true;
}

fn readU32(allocator: Allocator, io: Io, dir: Io.Dir, name: []const u8) ?u32 {
    const data = dir.readFileAlloc(io, name, allocator, .limited(64)) catch return null;
    defer allocator.free(data);
    return std.fmt.parseInt(u32, std.mem.trim(u8, data, " \t\r\n"), 10) catch null;
}

// ── Tag lookup ──────────────────────────────────────────────────

fn findPointsAtTags(allocator: Allocator, io: Io, repo_root: []const u8, count: *u32, timeout: Io.Timeout) ?[]const u8 {
    const out = runGit(allocator, io, repo_root, &.{ "git", "tag", "--points-at", "HEAD" }, timeout) orelse return null;
    defer allocator.free(out);

    var shortest: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        count.* += 1;
        if (shortest == null or line.len < shortest.?.len) {
            if (shortest) |old| allocator.free(old);
            shortest = allocator.dupe(u8, line) catch continue;
        }
    }
    return shortest;
}

fn isDir(io: Io, path: []const u8) bool {
    var dir = Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}

fn readSmallFile(allocator: Allocator, io: Io, path: []const u8) ?[]u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(8192)) catch null;
}

fn runGit(allocator: Allocator, io: Io, cwd: []const u8, argv: []const []const u8, timeout: Io.Timeout) ?[]u8 {
    const result = std.process.run(allocator, io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(256 * 1024),
        // 0.16 defaults stderr to .unlimited; cap it like stdout so a noisy
        // hook or corrupted repo can't buffer unbounded diagnostics.
        .stderr_limit = .limited(256 * 1024),
        .timeout = timeout,
    }) catch return null;
    allocator.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) {
        allocator.free(result.stdout);
        return null;
    }

    return result.stdout;
}

// ── Output writers ───────────────────────────────────────────────

pub fn writeGitCommit(w: *Writer, main_result: GitMainResult) !void {
    // Show hash only in detached HEAD mode
    if (main_result.branch == null) {
        const hash = main_result.hash orelse return;
        try w.writeAll(" ");
        try w.writeAll(style.cyan);
        try w.writeAll(&hash);
        try w.writeAll(style.reset);
    }
    // Show tag(s) if present — always, even on a branch
    if (main_result.tag) |tag| {
        try w.writeAll(" ");
        try w.writeAll(style.cyan);
        try w.writeAll("\xf0\x9f\x8f\xb7\xef\xb8\x8f"); // 🏷️
        if (main_result.tag_count > 1) {
            try w.print("({d}) ", .{main_result.tag_count});
        } else {
            try w.writeAll(" ");
        }
        try w.writeAll(tag);
        try w.writeAll(style.reset);
    }
}

pub fn writeGitBranch(w: *Writer, main_result: GitMainResult) !void {
    const branch = main_result.branch orelse return;
    try w.writeAll(" ");
    try w.writeAll(style.cyan);
    try w.writeAll(branch);
    if (main_result.remote) |remote| {
        // Hide remote if it's just "origin/<branch>" (the common default)
        const dominated = if (std.mem.startsWith(u8, remote, "origin/"))
            remote["origin/".len..]
        else
            null;
        if (dominated == null or !std.mem.eql(u8, dominated.?, branch)) {
            try w.writeAll("(:");
            try w.writeAll(remote);
            try w.writeAll(")");
        }
    }
    try w.writeAll(style.reset);
}

pub fn writeGitStatus(w: *Writer, s: GitStatus) !void {
    const has_status = s.conflicted > 0 or s.deleted > 0 or s.renamed > 0 or
        s.modified > 0 or s.untracked > 0 or s.staged > 0;
    const has_ab = s.ahead > 0 or s.behind > 0;
    if (!has_status and !has_ab) return;

    try w.writeAll(" ");
    if (s.conflicted > 0) try style.styled(w, style.yellow, "\xe2\x8a\x98"); // ⊘
    if (s.deleted > 0) try style.styled(w, style.red, "\xe2\x9c\x98"); // ✘
    if (s.renamed > 0) try style.styled(w, style.cyan, "\xc2\xbb"); // »
    if (s.modified > 0) try style.styled(w, style.yellow, "\xe2\x97\x8f"); // ●
    if (s.untracked > 0) try style.styled(w, style.fg_f60, "\xe2\x97\x8f"); // ●
    if (s.staged > 0) try style.styled(w, style.green, "\xe2\x97\x8f"); // ●

    if (s.ahead > 0 and s.behind > 0) {
        try style.styled(w, style.cyan, "\xe2\x96\xb4"); // ▴
        try style.styled(w, style.purple, "\xe2\x96\xbe"); // ▾
    } else if (s.ahead > 0) {
        try style.styled(w, style.cyan, "\xe2\x96\xb4");
    } else if (s.behind > 0) {
        try style.styled(w, style.purple, "\xe2\x96\xbe");
    }
}

pub fn writeGitState(w: *Writer, state: GitState) !void {
    try w.writeAll(" ");
    try w.writeAll(style.red);
    try w.writeAll(state.label);
    if (state.progress_current) |current| {
        if (state.progress_total) |total| {
            try w.writeAll(" ");
            try w.print("{d}/{d}", .{ current, total });
        }
    }
    try w.writeAll(style.reset);
}

pub fn writeGitMetrics(w: *Writer, metrics: GitMetrics) !void {
    if (metrics.added > 0) {
        try w.writeAll(" ");
        try w.writeAll(style.green);
        try w.print("+{d}", .{metrics.added});
        try w.writeAll(style.reset);
    }
    if (metrics.deleted > 0) {
        try w.writeAll(" ");
        try w.writeAll(style.red);
        try w.print("-{d}", .{metrics.deleted});
        try w.writeAll(style.reset);
    }
}

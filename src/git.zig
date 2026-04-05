const std = @import("std");
const style = @import("style.zig");

const Allocator = std.mem.Allocator;
const Writer = std.io.Writer;

// ── Data structures ──────────────────────────────────────────────

pub const GitMainResult = struct {
    branch: ?[]const u8 = null,
    remote: ?[]const u8 = null,
    hash: ?[7]u8 = null,
    tag: ?[]const u8 = null,
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

// ── Thread contexts ──────────────────────────────────────────────

pub const GitMainCtx = struct {
    event: std.Thread.ResetEvent = .{},
    allocator: Allocator,
    repo_root: []const u8,
    git_dir: []const u8,
    result: ?GitMainResult = null,
};

pub const GitExtrasCtx = struct {
    event: std.Thread.ResetEvent = .{},
    allocator: Allocator,
    git_dir: []const u8,
    repo_root: []const u8,
    result: ?GitExtrasResult = null,
};

// ── findGitRoot ──────────────────────────────────────────────────

pub const GitRoot = struct {
    repo_root: []const u8,
    git_dir: []const u8,
};

pub fn findGitRoot(allocator: Allocator, cwd: []const u8) ?GitRoot {
    var path = allocator.dupe(u8, cwd) catch return null;
    while (true) {
        const git_path = std.fmt.allocPrint(allocator, "{s}/.git", .{path}) catch {
            allocator.free(path);
            return null;
        };

        if (isDir(git_path)) {
            return GitRoot{ .repo_root = path, .git_dir = git_path };
        }

        if (readSmallFile(allocator, git_path)) |content| {
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

pub fn gitMainWorker(ctx: *GitMainCtx) void {
    defer ctx.event.set();
    ctx.result = doGitMain(ctx.allocator, ctx.repo_root, ctx.git_dir);
}

pub fn gitExtrasWorker(ctx: *GitExtrasCtx) void {
    defer ctx.event.set();
    ctx.result = doGitExtras(ctx.allocator, ctx.git_dir, ctx.repo_root);
}

fn doGitMain(allocator: Allocator, repo_root: []const u8, git_dir: []const u8) ?GitMainResult {
    var result = GitMainResult{};
    var full_oid: ?*const [40]u8 = null;

    const status_out = runGit(allocator, repo_root, &.{ "git", "status", "--porcelain=v2", "--branch" }) orelse return null;
    defer allocator.free(status_out);

    var lines = std.mem.splitScalar(u8, status_out, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        if (std.mem.startsWith(u8, line, "# branch.oid ")) {
            const oid = line["# branch.oid ".len..];
            if (oid.len >= 40 and !std.mem.eql(u8, oid[0..9], "(initial)")) {
                result.hash = oid[0..7].*;
                full_oid = oid[0..40];
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

    if (full_oid) |oid| {
        result.tag = findExactTag(allocator, git_dir, oid);
    }

    return result;
}

fn doGitExtras(allocator: Allocator, git_dir: []const u8, repo_root: []const u8) ?GitExtrasResult {
    var result = GitExtrasResult{};

    result.state = detectState(allocator, git_dir);

    const diff_out = runGit(allocator, repo_root, &.{ "git", "diff", "--numstat", "HEAD" }) orelse {
        const cached_out = runGit(allocator, repo_root, &.{ "git", "diff", "--numstat", "--cached" }) orelse return result;
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

fn detectState(allocator: Allocator, git_dir: []const u8) ?GitState {
    var dir = std.fs.cwd().openDir(git_dir, .{}) catch return null;
    defer dir.close();
    if (checkRebaseDir(allocator, dir, "rebase-merge", "msgnum", "end")) |s| return s;
    if (checkRebaseDir(allocator, dir, "rebase-apply", "next", "last")) |s| return s;
    if (dirHasFile(dir, "MERGE_HEAD")) return .{ .label = "MERGING" };
    if (dirHasFile(dir, "CHERRY_PICK_HEAD")) return .{ .label = "CHERRY-PICKING" };
    if (dirHasFile(dir, "REVERT_HEAD")) return .{ .label = "REVERTING" };
    if (dirHasFile(dir, "BISECT_LOG")) return .{ .label = "BISECTING" };
    return null;
}

fn checkRebaseDir(allocator: Allocator, parent: std.fs.Dir, dir_name: []const u8, current_file: []const u8, total_file: []const u8) ?GitState {
    var sub = parent.openDir(dir_name, .{}) catch return null;
    defer sub.close();
    var state = GitState{ .label = "REBASING" };
    state.progress_current = readU32(allocator, sub, current_file);
    state.progress_total = readU32(allocator, sub, total_file);
    return state;
}

fn dirHasFile(dir: std.fs.Dir, name: []const u8) bool {
    dir.access(name, .{}) catch return false;
    return true;
}

fn readU32(allocator: Allocator, dir: std.fs.Dir, name: []const u8) ?u32 {
    const data = dir.readFileAlloc(allocator, name, 64) catch return null;
    defer allocator.free(data);
    return std.fmt.parseInt(u32, std.mem.trim(u8, data, " \t\r\n"), 10) catch null;
}

// ── Tag lookup (.git/ direct read) ──────────────────────────────

fn findExactTag(allocator: Allocator, git_dir: []const u8, head_hash: *const [40]u8) ?[]const u8 {
    // 1. Check packed-refs (covers packed lightweight + annotated tags via ^ lines)
    if (findTagInPackedRefs(allocator, git_dir, head_hash)) |tag| return tag;
    // 2. Check loose tags in refs/tags/
    return findLooseTag(allocator, git_dir, head_hash);
}

fn findTagInPackedRefs(allocator: Allocator, git_dir: []const u8, head_hash: *const [40]u8) ?[]const u8 {
    var dir = std.fs.cwd().openDir(git_dir, .{}) catch return null;
    defer dir.close();
    const content = dir.readFileAlloc(allocator, "packed-refs", 1024 * 1024) catch return null;
    defer allocator.free(content);

    var prev_tag_name: ?[]const u8 = null; // points into content, no free needed
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') {
            prev_tag_name = null;
            continue;
        }
        // ^<hash> = dereferenced commit for the previous annotated tag
        if (line[0] == '^') {
            if (prev_tag_name) |name| {
                if (line.len >= 41 and std.mem.eql(u8, line[1..41], head_hash)) {
                    return allocator.dupe(u8, name) catch null;
                }
            }
            prev_tag_name = null;
            continue;
        }
        // <hash> <ref>
        prev_tag_name = null;
        if (line.len >= 52 and line[40] == ' ') { // 40 hash + ' ' + "refs/tags/" (10) + at least 1 char
            const ref = line[41..];
            if (std.mem.startsWith(u8, ref, "refs/tags/")) {
                const tag_name = ref["refs/tags/".len..];
                // Lightweight tag: hash matches HEAD directly
                if (std.mem.eql(u8, line[0..40], head_hash)) {
                    return allocator.dupe(u8, tag_name) catch null;
                }
                // Save for potential ^ dereference line
                prev_tag_name = tag_name;
            }
        }
    }
    return null;
}

fn findLooseTag(allocator: Allocator, git_dir: []const u8, head_hash: *const [40]u8) ?[]const u8 {
    const tags_path = std.fmt.allocPrint(allocator, "{s}/refs/tags", .{git_dir}) catch return null;
    defer allocator.free(tags_path);
    var tags_dir = std.fs.cwd().openDir(tags_path, .{ .iterate = true }) catch return null;
    defer tags_dir.close();

    var iter = tags_dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        const tag_content = tags_dir.readFileAlloc(allocator, entry.name, 256) catch continue;
        defer allocator.free(tag_content);
        const tag_hash = std.mem.trim(u8, tag_content, " \t\r\n");
        if (tag_hash.len >= 40) {
            // Lightweight tag: direct match
            if (std.mem.eql(u8, tag_hash[0..40], head_hash)) {
                return allocator.dupe(u8, entry.name) catch null;
            }
            // Annotated tag: read object and resolve target commit
            if (resolveTagObject(allocator, git_dir, tag_hash[0..40])) |target| {
                defer allocator.free(target);
                if (std.mem.eql(u8, target, head_hash)) {
                    return allocator.dupe(u8, entry.name) catch null;
                }
            }
        }
    }
    return null;
}

/// Read a git tag object and extract the target commit hash.
/// Returns the 40-char hex hash of the tagged commit, or null.
fn resolveTagObject(allocator: Allocator, git_dir: []const u8, obj_hash: *const [40]u8) ?[]const u8 {
    const obj_path = std.fmt.allocPrint(allocator, "{s}/objects/{s}/{s}", .{
        git_dir, obj_hash[0..2], obj_hash[2..],
    }) catch return null;
    defer allocator.free(obj_path);

    const compressed = std.fs.cwd().readFileAlloc(allocator, obj_path, 64 * 1024) catch return null;
    defer allocator.free(compressed);

    var input_reader = std.io.Reader.fixed(compressed);
    var decomp = std.compress.flate.Decompress.init(&input_reader, .zlib, &.{});
    const data = decomp.reader.allocRemaining(allocator, .unlimited) catch return null;
    defer allocator.free(data);

    // Format: "tag <size>\0object <40hex>\n..."
    // Find the null byte separating header from content
    const null_pos = std.mem.indexOfScalar(u8, data, 0) orelse return null;
    const header = data[0..null_pos];
    if (!std.mem.startsWith(u8, header, "tag ")) return null;

    const body = data[null_pos + 1 ..];
    if (std.mem.startsWith(u8, body, "object ") and body.len >= 47) {
        return allocator.dupe(u8, body[7..47]) catch null;
    }
    return null;
}

fn isDir(path: []const u8) bool {
    var dir = std.fs.cwd().openDir(path, .{}) catch return false;
    dir.close();
    return true;
}

fn readSmallFile(allocator: Allocator, path: []const u8) ?[]u8 {
    return std.fs.cwd().readFileAlloc(allocator, path, 8192) catch null;
}

fn runGit(allocator: Allocator, cwd: []const u8, argv: []const []const u8) ?[]u8 {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .cwd = cwd,
        .max_output_bytes = 256 * 1024,
    }) catch return null;
    allocator.free(result.stderr);

    if (result.term != .Exited or result.term.Exited != 0) {
        allocator.free(result.stdout);
        return null;
    }

    return result.stdout;
}

// ── Output writers ───────────────────────────────────────────────

pub fn writeGitCommit(w: *Writer, main_result: GitMainResult) !void {
    // On a branch HEAD: skip hash (branch name is enough)
    if (main_result.branch != null) return;
    // Detached HEAD: show hash + tag
    const hash = main_result.hash orelse return;
    try w.writeAll(" ");
    try w.writeAll(style.cyan);
    try w.writeAll(&hash);
    if (main_result.tag) |tag| {
        try w.writeAll(" ");
        try w.writeAll(tag);
    }
    try w.writeAll(style.reset);
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

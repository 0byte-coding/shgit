const std = @import("std");

const log = std.log.scoped(.git);

/// Run a git command and return success/failure
fn run_git(io: std.Io, allocator: std.mem.Allocator, cwd: ?[]const u8, args: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);

    try argv.append(allocator, "git");
    try argv.appendSlice(allocator, args);

    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .cwd = if (cwd) |p| .{ .path = p } else .inherit,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    _ = try child.wait(io);
}

/// Run a git command silently and return true if it exited successfully (code 0).
/// stdout/stderr are discarded so callers can probe git state without noise.
fn run_git_probe(io: std.Io, allocator: std.mem.Allocator, cwd: ?[]const u8, args: []const []const u8) !bool {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);

    try argv.append(allocator, "git");
    try argv.appendSlice(allocator, args);

    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .cwd = if (cwd) |p| .{ .path = p } else .inherit,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try child.wait(io);
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

/// Returns true if `rel_path` is tracked by git in the repo/worktree at `repo_path`.
pub fn is_tracked(io: std.Io, allocator: std.mem.Allocator, repo_path: []const u8, rel_path: []const u8) !bool {
    return run_git_probe(io, allocator, repo_path, &.{ "ls-files", "--error-unmatch", "--", rel_path });
}

/// Mark a tracked file with `--skip-worktree` so local changes/deletions are
/// hidden from git status. No-op semantics if the file is not tracked (git errors).
pub fn skip_worktree(io: std.Io, allocator: std.mem.Allocator, repo_path: []const u8, rel_path: []const u8) !void {
    const ok = try run_git_probe(io, allocator, repo_path, &.{ "update-index", "--skip-worktree", "--", rel_path });
    if (!ok) {
        log.warn("could not set skip-worktree on {s}", .{rel_path});
    } else {
        log.debug("skip-worktree set on {s}", .{rel_path});
    }
}

/// Clear `--skip-worktree` on a tracked file (used by teardown/unlink flows).
pub fn no_skip_worktree(io: std.Io, allocator: std.mem.Allocator, repo_path: []const u8, rel_path: []const u8) !void {
    const ok = try run_git_probe(io, allocator, repo_path, &.{ "update-index", "--no-skip-worktree", "--", rel_path });
    if (!ok) {
        log.debug("could not clear skip-worktree on {s} (maybe untracked)", .{rel_path});
    }
}

/// Run `git ls-files <extra_args...>` and return the newline-separated paths as
/// a list of owned strings (relative, `/`-separated). Caller owns each string
/// and the slice.
fn run_ls_files(io: std.Io, allocator: std.mem.Allocator, repo_path: []const u8, extra_args: []const []const u8) ![][]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);

    try argv.append(allocator, "git");
    try argv.append(allocator, "ls-files");
    try argv.appendSlice(allocator, extra_args);

    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .cwd = .{ .path = repo_path },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    });

    const stdout_file = child.stdout.?;
    var read_buf: [4096]u8 = undefined;
    var r = stdout_file.reader(io, &read_buf);
    const stdout = try r.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(stdout);

    _ = try child.wait(io);

    var files: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (files.items) |f| allocator.free(f);
        files.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0) continue;
        try files.append(allocator, try allocator.dupe(u8, trimmed));
    }

    return try files.toOwnedSlice(allocator);
}

/// Return the list of files tracked by git in the repo/worktree at `repo_path`
/// (relative paths, `/`-separated). Caller owns each string and the slice.
pub fn list_tracked_files(io: std.Io, allocator: std.mem.Allocator, repo_path: []const u8) ![][]const u8 {
    return run_ls_files(io, allocator, repo_path, &.{});
}

/// Return every file git knows about that is NOT gitignored: tracked files plus
/// untracked files, with all standard ignore rules applied (`.gitignore`,
/// `.git/info/exclude`, global excludes). This is the correct set to scan when
/// applying `remove_patterns`, so ignored trees like `node_modules/` are skipped.
/// Caller owns each string and the slice.
pub fn list_non_ignored_files(io: std.Io, allocator: std.mem.Allocator, repo_path: []const u8) ![][]const u8 {
    return run_ls_files(io, allocator, repo_path, &.{ "--cached", "--others", "--exclude-standard" });
}

/// Restore a tracked file to its committed (HEAD-index) contents in the working
/// tree, undoing a shadow or a removal. Returns true on success.
pub fn restore_file(io: std.Io, allocator: std.mem.Allocator, repo_path: []const u8, rel_path: []const u8) !bool {
    const ok = try run_git_probe(io, allocator, repo_path, &.{ "checkout", "--", rel_path });
    if (!ok) {
        log.warn("could not restore {s}", .{rel_path});
    } else {
        log.debug("restored {s}", .{rel_path});
    }
    return ok;
}

/// Initialize a git repository
pub fn init(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
    log.info("git init {s}", .{path});
    try run_git(io, allocator, path, &.{ "init", "-b", "main" });
}

/// Add a git submodule
pub fn add_submodule(io: std.Io, allocator: std.mem.Allocator, cwd: []const u8, url: []const u8, path: []const u8) !void {
    log.info("adding submodule {s} at {s}", .{ url, path });
    try run_git(io, allocator, cwd, &.{ "submodule", "add", url, path });
}

/// Add a git worktree (simple wrapper)
pub fn add_worktree(io: std.Io, allocator: std.mem.Allocator, repo_path: []const u8, worktree_path: []const u8, branch: []const u8, create_branch: bool, start_point: ?[]const u8) !void {
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);

    try args.append(allocator, "worktree");
    try args.append(allocator, "add");

    if (create_branch) {
        try args.append(allocator, "-b");
        try args.append(allocator, branch);
        if (start_point) |sp| {
            log.info("creating new worktree {s} with new branch {s} from {s}", .{ worktree_path, branch, sp });
        } else {
            log.info("creating new worktree {s} with new branch {s}", .{ worktree_path, branch });
        }
    } else {
        log.info("creating worktree {s} from existing branch {s}", .{ worktree_path, branch });
    }

    try args.append(allocator, worktree_path);

    if (!create_branch) {
        try args.append(allocator, branch);
    } else if (start_point) |sp| {
        try args.append(allocator, sp);
    }

    try run_git(io, allocator, repo_path, args.items);
}

/// Remove a git worktree
pub fn remove_worktree(io: std.Io, allocator: std.mem.Allocator, repo_path: []const u8, worktree_path: []const u8, force: bool) !void {
    log.info("removing worktree {s}", .{worktree_path});
    if (force) {
        try run_git(io, allocator, repo_path, &.{ "worktree", "remove", "--force", worktree_path });
    } else {
        try run_git(io, allocator, repo_path, &.{ "worktree", "remove", worktree_path });
    }
}

/// Prune stale worktree metadata
pub fn prune_worktrees(io: std.Io, allocator: std.mem.Allocator, repo_path: []const u8) !void {
    log.info("pruning worktrees in {s}", .{repo_path});
    try run_git(io, allocator, repo_path, &.{ "worktree", "prune" });
}

/// List git worktrees
pub fn list_worktrees(io: std.Io, allocator: std.mem.Allocator, repo_path: []const u8) !void {
    try run_git(io, allocator, repo_path, &.{ "worktree", "list" });
}

/// Get list of worktree paths
pub fn get_worktree_paths(io: std.Io, allocator: std.mem.Allocator, repo_path: []const u8) ![][]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);

    try argv.append(allocator, "git");
    try argv.append(allocator, "worktree");
    try argv.append(allocator, "list");
    try argv.append(allocator, "--porcelain");

    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .cwd = .{ .path = repo_path },
        .stdin = .inherit,
        .stdout = .pipe,
        .stderr = .inherit,
    });

    const stdout_file = child.stdout.?;
    var read_buf: [4096]u8 = undefined;
    var r = stdout_file.reader(io, &read_buf);
    const stdout = try r.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(stdout);

    _ = try child.wait(io);

    // Parse porcelain format
    // Each worktree is separated by blank line
    // Format:
    // worktree /path/to/worktree
    // HEAD ...
    // branch ...
    //
    var paths: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "worktree ")) {
            const path = line[9..]; // Skip "worktree "
            try paths.append(allocator, try allocator.dupe(u8, path));
        }
    }

    return try paths.toOwnedSlice(allocator);
}

/// Add a path to .git/info/exclude (local gitignore)
pub fn add_local_exclude(io: std.Io, allocator: std.mem.Allocator, repo_path: []const u8, rel_path: []const u8) !void {
    // Find .git directory (could be a file for worktrees)
    const git_path = try std.fs.path.join(allocator, &.{ repo_path, ".git" });
    defer allocator.free(git_path);

    var actual_git_dir: []const u8 = undefined;
    var allocated_git_dir = false;
    defer if (allocated_git_dir) allocator.free(actual_git_dir);

    const stat = std.Io.Dir.cwd().statFile(io, git_path, .{}) catch |err| {
        log.warn("could not stat .git: {}", .{err});
        return;
    };

    if (stat.kind == .file) {
        // Worktree/submodule - .git is a file pointing to actual git dir
        const file = try std.Io.Dir.cwd().openFile(io, git_path, .{});
        defer file.close(io);

        var buf: [4096]u8 = undefined;
        var r = file.reader(io, &buf);
        const content = try r.interface.allocRemaining(allocator, .unlimited);
        defer allocator.free(content);

        // Find first newline
        const newline_pos = std.mem.indexOfScalar(u8, content, '\n') orelse content.len;
        const first_line = content[0..newline_pos];

        // Parse "gitdir: /path/to/git"
        if (std.mem.startsWith(u8, first_line, "gitdir: ")) {
            const gitdir_path = first_line[8..];
            // If path is relative, resolve it relative to repo_path
            if (std.fs.path.isAbsolute(gitdir_path)) {
                actual_git_dir = try allocator.dupe(u8, gitdir_path);
            } else {
                actual_git_dir = try std.fs.path.join(allocator, &.{ repo_path, gitdir_path });
            }
            allocated_git_dir = true;
        } else {
            log.warn("unexpected .git file content", .{});
            return;
        }
    } else {
        actual_git_dir = git_path;
    }

    // Ensure info directory exists
    const info_dir = try std.fs.path.join(allocator, &.{ actual_git_dir, "info" });
    defer allocator.free(info_dir);
    std.Io.Dir.cwd().createDirPath(io, info_dir) catch {};

    // Append to exclude file
    const exclude_path = try std.fs.path.join(allocator, &.{ actual_git_dir, "info", "exclude" });
    defer allocator.free(exclude_path);

    // Read existing content to check if already excluded
    var existing_content: []u8 = &.{};
    var existing_allocated = false;
    defer if (existing_allocated) allocator.free(existing_content);

    if (std.Io.Dir.cwd().openFile(io, exclude_path, .{})) |file| {
        defer file.close(io);
        var buf: [4096]u8 = undefined;
        var r = file.reader(io, &buf);
        existing_content = r.interface.allocRemaining(allocator, .unlimited) catch &.{};
        existing_allocated = true;
    } else |_| {}

    // Check if already in exclude
    const search_pattern = try std.fmt.allocPrint(allocator, "/{s}", .{rel_path});
    defer allocator.free(search_pattern);

    if (std.mem.indexOf(u8, existing_content, search_pattern) != null) {
        return; // Already excluded
    }

    // Build the line to append
    const needs_newline = existing_content.len > 0 and existing_content[existing_content.len - 1] != '\n';
    const line = if (needs_newline)
        try std.fmt.allocPrint(allocator, "\n/{s}\n", .{rel_path})
    else
        try std.fmt.allocPrint(allocator, "/{s}\n", .{rel_path});
    defer allocator.free(line);

    // Open for writing (no truncate) and write at end
    const file = try std.Io.Dir.cwd().createFile(io, exclude_path, .{ .truncate = false });
    defer file.close(io);
    try file.writePositionalAll(io, line, existing_content.len);

    log.debug("added {s} to local exclude at {s}", .{ rel_path, exclude_path });
}

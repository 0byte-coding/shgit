const std = @import("std");

const log = std.log.scoped(.git);

/// Run a git command and return success/failure
fn runGit(io: std.Io, allocator: std.mem.Allocator, cwd: ?[]const u8, args: []const []const u8) !void {
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

/// Initialize a git repository
pub fn init(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
    log.info("git init {s}", .{path});
    try runGit(io, allocator, path, &.{ "init", "-b", "main" });
}

/// Add a git submodule
pub fn addSubmodule(io: std.Io, allocator: std.mem.Allocator, cwd: []const u8, url: []const u8, path: []const u8) !void {
    log.info("adding submodule {s} at {s}", .{ url, path });
    try runGit(io, allocator, cwd, &.{ "submodule", "add", url, path });
}

/// Add a git worktree (simple wrapper)
pub fn addWorktree(io: std.Io, allocator: std.mem.Allocator, repo_path: []const u8, worktree_path: []const u8, branch: []const u8, create_branch: bool, start_point: ?[]const u8) !void {
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

    try runGit(io, allocator, repo_path, args.items);
}

/// Remove a git worktree
pub fn removeWorktree(io: std.Io, allocator: std.mem.Allocator, repo_path: []const u8, worktree_path: []const u8, force: bool) !void {
    log.info("removing worktree {s}", .{worktree_path});
    if (force) {
        try runGit(io, allocator, repo_path, &.{ "worktree", "remove", "--force", worktree_path });
    } else {
        try runGit(io, allocator, repo_path, &.{ "worktree", "remove", worktree_path });
    }
}

/// Prune stale worktree metadata
pub fn pruneWorktrees(io: std.Io, allocator: std.mem.Allocator, repo_path: []const u8) !void {
    log.info("pruning worktrees in {s}", .{repo_path});
    try runGit(io, allocator, repo_path, &.{ "worktree", "prune" });
}

/// List git worktrees
pub fn listWorktrees(io: std.Io, allocator: std.mem.Allocator, repo_path: []const u8) !void {
    try runGit(io, allocator, repo_path, &.{ "worktree", "list" });
}

/// Get list of worktree paths
pub fn getWorktreePaths(io: std.Io, allocator: std.mem.Allocator, repo_path: []const u8) ![][]const u8 {
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
pub fn addLocalExclude(io: std.Io, allocator: std.mem.Allocator, repo_path: []const u8, rel_path: []const u8) !void {
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

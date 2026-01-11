const std = @import("std");

const log = std.log.scoped(.git);

/// Run a git command and return success/failure
fn runGit(allocator: std.mem.Allocator, cwd: ?[]const u8, args: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);

    try argv.append(allocator, "git");
    try argv.appendSlice(allocator, args);

    var child = std.process.Child.init(argv.items, allocator);
    child.cwd = cwd;
    child.stderr_behavior = .Inherit;
    child.stdout_behavior = .Inherit;

    _ = try child.spawnAndWait();
}

/// Initialize a git repository
pub fn init(allocator: std.mem.Allocator, path: []const u8) !void {
    log.info("git init {s}", .{path});
    try runGit(allocator, path, &.{ "init", "-b", "main" });
}

/// Add a git submodule
pub fn addSubmodule(allocator: std.mem.Allocator, cwd: []const u8, url: []const u8, path: []const u8) !void {
    log.info("adding submodule {s} at {s}", .{ url, path });
    try runGit(allocator, cwd, &.{ "submodule", "add", url, path });
}

/// Add a git worktree
pub fn addWorktree(allocator: std.mem.Allocator, repo_path: []const u8, worktree_path: []const u8, branch: []const u8) !void {
    log.info("adding worktree {s} with branch {s}", .{ worktree_path, branch });
    try runGit(allocator, repo_path, &.{ "worktree", "add", "-b", branch, worktree_path });
}

/// Remove a git worktree
pub fn removeWorktree(allocator: std.mem.Allocator, repo_path: []const u8, worktree_path: []const u8) !void {
    log.info("removing worktree {s}", .{worktree_path});
    try runGit(allocator, repo_path, &.{ "worktree", "remove", worktree_path });
}

/// List git worktrees
pub fn listWorktrees(allocator: std.mem.Allocator, repo_path: []const u8) !void {
    try runGit(allocator, repo_path, &.{ "worktree", "list" });
}

/// Add a path to .git/info/exclude (local gitignore)
pub fn addLocalExclude(allocator: std.mem.Allocator, repo_path: []const u8, rel_path: []const u8) !void {
    // Find .git directory (could be a file for worktrees)
    const git_path = try std.fs.path.join(allocator, &.{ repo_path, ".git" });
    defer allocator.free(git_path);

    var actual_git_dir: []const u8 = undefined;
    var allocated_git_dir = false;
    defer if (allocated_git_dir) allocator.free(actual_git_dir);

    const stat = std.fs.cwd().statFile(git_path) catch |err| {
        log.warn("could not stat .git: {}", .{err});
        return;
    };

    if (stat.kind == .file) {
        // Worktree - .git is a file pointing to actual git dir
        const file = try std.fs.cwd().openFile(git_path, .{});
        defer file.close();

        // Read the first line to get gitdir path
        const content = try file.readToEndAlloc(allocator, 4096);
        defer allocator.free(content);

        // Find first newline
        const newline_pos = std.mem.indexOfScalar(u8, content, '\n') orelse content.len;
        const first_line = content[0..newline_pos];

        // Parse "gitdir: /path/to/git"
        if (std.mem.startsWith(u8, first_line, "gitdir: ")) {
            actual_git_dir = try allocator.dupe(u8, first_line[8..]);
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
    std.fs.cwd().makePath(info_dir) catch {};

    // Append to exclude file
    const exclude_path = try std.fs.path.join(allocator, &.{ actual_git_dir, "info", "exclude" });
    defer allocator.free(exclude_path);

    // Read existing content to check if already excluded
    var existing_content: []u8 = &.{};
    var existing_allocated = false;
    defer if (existing_allocated) allocator.free(existing_content);

    if (std.fs.cwd().openFile(exclude_path, .{})) |file| {
        defer file.close();
        existing_content = file.readToEndAlloc(allocator, 1024 * 1024) catch &.{};
        existing_allocated = true;
    } else |_| {}

    // Check if already in exclude
    const search_pattern = try std.fmt.allocPrint(allocator, "/{s}", .{rel_path});
    defer allocator.free(search_pattern);

    if (std.mem.indexOf(u8, existing_content, search_pattern) != null) {
        return; // Already excluded
    }

    // Append to exclude
    const file = try std.fs.cwd().createFile(exclude_path, .{ .truncate = false });
    defer file.close();

    try file.seekFromEnd(0);

    // Add newline if needed
    if (existing_content.len > 0 and existing_content[existing_content.len - 1] != '\n') {
        try file.writeAll("\n");
    }

    var buf: [1024]u8 = undefined;
    var file_writer = file.writer(&buf);
    try file_writer.interface.print("/{s}\n", .{rel_path});
    try file_writer.interface.flush();

    log.debug("added {s} to local exclude", .{rel_path});
}

test "git module compiles" {
    _ = init;
    _ = addSubmodule;
    _ = addWorktree;
}

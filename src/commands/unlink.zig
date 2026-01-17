const std = @import("std");
const config = @import("../config.zig");
const git = @import("../git.zig");

const log = std.log.scoped(.unlink);

pub fn execute(allocator: std.mem.Allocator, args: anytype, verbose: bool) !void {
    _ = verbose;

    const rel_path = args.positionals.PATH;

    // Find shgit root
    const shgit_root = try config.findShgitRoot(allocator) orelse {
        log.err("not in a shgit project (no .shgit directory found)", .{});
        return error.NotShgitProject;
    };
    defer allocator.free(shgit_root);

    log.info("shgit root: {s}", .{shgit_root});

    // Load config
    var cfg = try config.loadConfig(allocator, shgit_root);
    defer cfg.deinit(allocator);

    // Determine target
    const target_name = cfg.main_repo orelse {
        log.err("no main_repo in config", .{});
        return error.NoMainRepo;
    };

    const target_dir = try std.fs.path.join(allocator, &.{ shgit_root, config.REPO_DIR, target_name });
    defer allocator.free(target_dir);

    // Unlink from main repo
    log.info("unlinking {s} from repo/{s}/", .{ rel_path, target_name });
    try unlinkFile(allocator, target_dir, rel_path);

    // Get all worktrees and unlink from them too
    const worktree_paths = git.getWorktreePaths(allocator, target_dir) catch |err| {
        if (err == error.FileNotFound) {
            // Not a git repo or no worktrees, skip
            log.info("unlinking complete", .{});
            return;
        }
        return err;
    };
    defer {
        for (worktree_paths) |p| allocator.free(p);
        allocator.free(worktree_paths);
    }

    // Construct the repo directory base path for filtering
    const repo_base = try std.fs.path.join(allocator, &.{ shgit_root, config.REPO_DIR });
    defer allocator.free(repo_base);

    // Unlink from each worktree
    for (worktree_paths) |worktree_path| {
        // Skip if it's not in the repo/ directory (e.g., .git/modules paths for submodules)
        if (!std.mem.startsWith(u8, worktree_path, repo_base)) continue;

        // Skip if it's the same as target_dir (already unlinked)
        if (std.mem.eql(u8, worktree_path, target_dir)) continue;

        const worktree_name = std.fs.path.basename(worktree_path);
        log.info("unlinking {s} from repo/{s}/", .{ rel_path, worktree_name });

        try unlinkFile(allocator, worktree_path, rel_path);
    }

    log.info("unlinking complete", .{});
}

fn unlinkFile(
    allocator: std.mem.Allocator,
    repo_path: []const u8,
    rel_path: []const u8,
) !void {
    const target_file = try std.fs.path.join(allocator, &.{ repo_path, rel_path });
    defer allocator.free(target_file);

    // Try to delete the file/symlink
    std.fs.cwd().deleteFile(target_file) catch |err| {
        if (err == error.FileNotFound) {
            // File doesn't exist, that's fine
            log.debug("file not found (already unlinked): {s}", .{target_file});
            return;
        }
        log.warn("could not delete {s}: {}", .{ target_file, err });
        return;
    };

    log.info("unlinked: {s}", .{rel_path});

    // Remove from local git exclude
    try removeFromLocalExclude(allocator, repo_path, rel_path);
}

fn removeFromLocalExclude(
    allocator: std.mem.Allocator,
    repo_path: []const u8,
    rel_path: []const u8,
) !void {
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
        // Worktree/submodule - .git is a file pointing to actual git dir
        const file = try std.fs.cwd().openFile(git_path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 4096);
        defer allocator.free(content);

        const newline_pos = std.mem.indexOfScalar(u8, content, '\n') orelse content.len;
        const first_line = content[0..newline_pos];

        if (std.mem.startsWith(u8, first_line, "gitdir: ")) {
            const gitdir_path = first_line[8..];
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

    const exclude_path = try std.fs.path.join(allocator, &.{ actual_git_dir, "info", "exclude" });
    defer allocator.free(exclude_path);

    // Read existing content
    const file = std.fs.cwd().openFile(exclude_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            // No exclude file, nothing to remove
            return;
        }
        return err;
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    // Find and remove the line with this path
    const search_pattern = try std.fmt.allocPrint(allocator, "/{s}", .{rel_path});
    defer allocator.free(search_pattern);

    var new_content: std.ArrayList(u8) = .empty;
    defer new_content.deinit(allocator);

    var lines = std.mem.splitScalar(u8, content, '\n');
    var found = false;
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, search_pattern)) {
            found = true;
            continue; // Skip this line
        }
        try new_content.appendSlice(allocator, line);
        try new_content.append(allocator, '\n');
    }

    if (!found) {
        // Pattern not in exclude file, nothing to do
        return;
    }

    // Write back the modified content
    const out_file = try std.fs.cwd().createFile(exclude_path, .{ .truncate = true });
    defer out_file.close();

    try out_file.writeAll(new_content.items);

    log.debug("removed {s} from local exclude", .{rel_path});
}

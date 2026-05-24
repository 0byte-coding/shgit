const std = @import("std");
const config = @import("../config.zig");
const git = @import("../git.zig");

const log = std.log.scoped(.unlink);

pub const UnlinkArgs = struct {
    path: []const u8,
};

pub fn execute(io: std.Io, allocator: std.mem.Allocator, args: UnlinkArgs, verbose: bool) !void {
    _ = verbose;

    const rel_path = args.path;

    // Find shgit root
    const shgit_root = try config.findShgitRoot(io, allocator) orelse {
        log.err("not in a shgit project (no .shgit directory found)", .{});
        return error.NotShgitProject;
    };
    defer allocator.free(shgit_root);

    log.info("shgit root: {s}", .{shgit_root});

    // Load config
    var cfg = try config.loadConfig(io, allocator, shgit_root);
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
    try unlinkFile(io, allocator, target_dir, rel_path);

    // Get all worktrees and unlink from them too
    const worktree_paths = git.getWorktreePaths(io, allocator, target_dir) catch |err| {
        if (err == error.FileNotFound) {
            log.info("unlinking complete", .{});
            return;
        }
        return err;
    };
    defer {
        for (worktree_paths) |p| allocator.free(p);
        allocator.free(worktree_paths);
    }

    const repo_base = try std.fs.path.join(allocator, &.{ shgit_root, config.REPO_DIR });
    defer allocator.free(repo_base);

    for (worktree_paths) |worktree_path| {
        if (!std.mem.startsWith(u8, worktree_path, repo_base)) continue;
        if (std.mem.eql(u8, worktree_path, target_dir)) continue;

        const worktree_name = std.fs.path.basename(worktree_path);
        log.info("unlinking {s} from repo/{s}/", .{ rel_path, worktree_name });

        try unlinkFile(io, allocator, worktree_path, rel_path);
    }

    log.info("unlinking complete", .{});
}

fn unlinkFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    repo_path: []const u8,
    rel_path: []const u8,
) !void {
    const target_file = try std.fs.path.join(allocator, &.{ repo_path, rel_path });
    defer allocator.free(target_file);

    std.Io.Dir.cwd().deleteFile(io, target_file) catch |err| {
        if (err == error.FileNotFound) {
            log.debug("file not found (already unlinked): {s}", .{target_file});
            return;
        }
        log.warn("could not delete {s}: {}", .{ target_file, err });
        return;
    };

    log.info("unlinked: {s}", .{rel_path});

    try removeFromLocalExclude(io, allocator, repo_path, rel_path);
}

fn removeFromLocalExclude(
    io: std.Io,
    allocator: std.mem.Allocator,
    repo_path: []const u8,
    rel_path: []const u8,
) !void {
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
        const file = try std.Io.Dir.cwd().openFile(io, git_path, .{});
        defer file.close(io);

        var buf: [4096]u8 = undefined;
        var r = file.reader(io, &buf);
        const content = try r.interface.allocRemaining(allocator, .unlimited);
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

    const file = std.Io.Dir.cwd().openFile(io, exclude_path, .{}) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer file.close(io);

    var read_buf: [4096]u8 = undefined;
    var r = file.reader(io, &read_buf);
    const content = try r.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(content);

    const search_pattern = try std.fmt.allocPrint(allocator, "/{s}", .{rel_path});
    defer allocator.free(search_pattern);

    var new_content: std.ArrayList(u8) = .empty;
    defer new_content.deinit(allocator);

    var lines = std.mem.splitScalar(u8, content, '\n');
    var found = false;
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, search_pattern)) {
            found = true;
            continue;
        }
        try new_content.appendSlice(allocator, line);
        try new_content.append(allocator, '\n');
    }

    if (!found) return;

    const out_file = try std.Io.Dir.cwd().createFile(io, exclude_path, .{ .truncate = true });
    defer out_file.close(io);
    try out_file.writeStreamingAll(io, new_content.items);

    log.debug("removed {s} from local exclude", .{rel_path});
}

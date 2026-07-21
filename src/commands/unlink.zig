const std = @import("std");
const config = @import("../config.zig");
const fs_utils = @import("../fs_utils.zig");
const git = @import("../git.zig");

const log = std.log.scoped(.unlink);

pub const UnlinkArgs = struct {
    /// Relative path to unlink. If null, revert the entire shgit overlay
    /// (all symlinks from link/ and all remove_patterns) across every repo/worktree.
    path: ?[]const u8 = null,
};

pub fn execute(io: std.Io, allocator: std.mem.Allocator, args: UnlinkArgs, verbose: bool) !void {
    _ = verbose;

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

    // Gather the list of repos to operate on: the main repo plus every worktree.
    var repos: std.ArrayList([]const u8) = .empty;
    defer {
        for (repos.items) |p| allocator.free(p);
        repos.deinit(allocator);
    }
    try repos.append(allocator, try allocator.dupe(u8, target_dir));

    const repo_base = try std.fs.path.join(allocator, &.{ shgit_root, config.REPO_DIR });
    defer allocator.free(repo_base);

    if (git.getWorktreePaths(io, allocator, target_dir)) |worktree_paths| {
        defer {
            for (worktree_paths) |p| allocator.free(p);
            allocator.free(worktree_paths);
        }
        for (worktree_paths) |worktree_path| {
            if (!std.mem.startsWith(u8, worktree_path, repo_base)) continue;
            if (std.mem.eql(u8, worktree_path, target_dir)) continue;
            try repos.append(allocator, try allocator.dupe(u8, worktree_path));
        }
    } else |err| {
        if (err != error.FileNotFound) return err;
    }

    if (args.path) |rel_path| {
        // Single-file mode.
        for (repos.items) |repo| {
            const name = std.fs.path.basename(repo);
            log.info("reverting {s} in repo/{s}/", .{ rel_path, name });
            try revertFile(io, allocator, repo, rel_path);
        }
        log.info("unlink complete", .{});
        return;
    }

    // Full-revert mode.
    const link_dir = try std.fs.path.join(allocator, &.{ shgit_root, config.LINK_DIR });
    defer allocator.free(link_dir);

    for (repos.items) |repo| {
        const name = std.fs.path.basename(repo);
        log.info("reverting overlay in repo/{s}/", .{name});

        // 1. Undo every symlink that mirrors a file in link/.
        try revertLinkDirectory(io, allocator, link_dir, repo, "");

        // 2. Undelete files that remove_patterns removed (tracked files only can
        //    be restored; untracked files are simply gone and stay gone).
        for (cfg.remove_patterns) |pattern| {
            try restoreRemovedPattern(io, allocator, repo, pattern);
        }
    }

    log.info("unlink complete", .{});
}

/// Walk the link/ tree and revert each corresponding file in `repo_base`.
fn revertLinkDirectory(
    io: std.Io,
    allocator: std.mem.Allocator,
    link_base: []const u8,
    repo_base: []const u8,
    rel_path: []const u8,
) !void {
    const link_path = if (rel_path.len > 0)
        try std.fs.path.join(allocator, &.{ link_base, rel_path })
    else
        try allocator.dupe(u8, link_base);
    defer allocator.free(link_path);

    var dir = std.Io.Dir.cwd().openDir(io, link_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        const new_rel = if (rel_path.len > 0)
            try std.fs.path.join(allocator, &.{ rel_path, entry.name })
        else
            try allocator.dupe(u8, entry.name);
        defer allocator.free(new_rel);

        if (entry.kind == .directory) {
            try revertLinkDirectory(io, allocator, link_base, repo_base, new_rel);
        } else {
            try revertFile(io, allocator, repo_base, new_rel);
        }
    }
}

/// Revert a single overlaid file at `rel_path` inside `repo_path`.
/// If the file is tracked, clear skip-worktree and restore its committed
/// contents. If it is untracked, remove the symlink and its exclude entry.
fn revertFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    repo_path: []const u8,
    rel_path: []const u8,
) !void {
    const tracked = git.isTracked(io, allocator, repo_path, rel_path) catch false;

    if (tracked) {
        // Clear the shadow flag, then delete our symlink and check out the
        // original file so the working tree matches HEAD again.
        git.noSkipWorktree(io, allocator, repo_path, rel_path) catch |err| {
            log.warn("could not clear skip-worktree on {s}: {}", .{ rel_path, err });
        };

        const target_file = try std.fs.path.join(allocator, &.{ repo_path, rel_path });
        defer allocator.free(target_file);
        std.Io.Dir.cwd().deleteFile(io, target_file) catch |err| {
            if (err != error.FileNotFound) {
                log.warn("could not remove {s}: {}", .{ target_file, err });
            }
        };

        _ = git.restoreFile(io, allocator, repo_path, rel_path) catch |err| {
            log.warn("could not restore {s}: {}", .{ rel_path, err });
        };
        log.info("restored tracked: {s}", .{rel_path});
    } else {
        // Untracked overlay: delete the symlink and clean the exclude entry.
        const target_file = try std.fs.path.join(allocator, &.{ repo_path, rel_path });
        defer allocator.free(target_file);

        std.Io.Dir.cwd().deleteFile(io, target_file) catch |err| {
            if (err == error.FileNotFound) {
                log.debug("nothing to remove at {s}", .{target_file});
            } else {
                log.warn("could not delete {s}: {}", .{ target_file, err });
            }
        };

        removeFromLocalExclude(io, allocator, repo_path, rel_path) catch |err| {
            log.warn("could not clean exclude for {s}: {}", .{ rel_path, err });
        };
        log.info("unlinked: {s}", .{rel_path});
    }
}

/// Restore files a remove_pattern deleted. We ask git for the tracked files
/// matching the pattern (via our glob matcher over the tracked file list) and
/// restore each one.
fn restoreRemovedPattern(
    io: std.Io,
    allocator: std.mem.Allocator,
    repo_path: []const u8,
    pattern: []const u8,
) !void {
    const tracked_files = git.listTrackedFiles(io, allocator, repo_path) catch |err| {
        log.warn("could not list tracked files: {}", .{err});
        return;
    };
    defer {
        for (tracked_files) |f| allocator.free(f);
        allocator.free(tracked_files);
    }

    for (tracked_files) |rel| {
        if (!fs_utils.matchGlob(rel, pattern)) continue;

        git.noSkipWorktree(io, allocator, repo_path, rel) catch |err| {
            log.warn("could not clear skip-worktree on {s}: {}", .{ rel, err });
        };
        if (git.restoreFile(io, allocator, repo_path, rel) catch false) {
            log.info("undeleted: {s}", .{rel});
        }
    }
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

    // Preserve the file's original trailing-newline state instead of forcing one.
    const had_trailing_nl = content.len > 0 and content[content.len - 1] == '\n';

    var lines = std.mem.splitScalar(u8, content, '\n');
    var found = false;
    var first = true;
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, search_pattern)) {
            found = true;
            continue;
        }
        if (!first) try new_content.append(allocator, '\n');
        first = false;
        try new_content.appendSlice(allocator, line);
    }

    if (!found) return;

    // std.mem.splitScalar yields a trailing empty segment for a trailing '\n';
    // the loop above already dropped it, so re-add a single newline if needed.
    if (had_trailing_nl and new_content.items.len > 0 and
        new_content.items[new_content.items.len - 1] != '\n')
    {
        try new_content.append(allocator, '\n');
    }

    const out_file = try std.Io.Dir.cwd().createFile(io, exclude_path, .{ .truncate = true });
    defer out_file.close(io);
    try out_file.writeStreamingAll(io, new_content.items);

    log.debug("removed {s} from local exclude", .{rel_path});
}

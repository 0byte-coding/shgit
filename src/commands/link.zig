const std = @import("std");
const config = @import("../config.zig");
const fs_utils = @import("../fs_utils.zig");
const git = @import("../git.zig");

const log = std.log.scoped(.link);

pub fn execute(allocator: std.mem.Allocator, args: anytype, verbose: bool) !void {
    _ = verbose;

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
    const target_name = args.options.target orelse cfg.main_repo orelse {
        log.err("no target specified and no main_repo in config", .{});
        return error.NoTarget;
    };

    const link_dir = try std.fs.path.join(allocator, &.{ shgit_root, config.LINK_DIR });
    defer allocator.free(link_dir);

    const target_dir = try std.fs.path.join(allocator, &.{ shgit_root, config.REPO_DIR, target_name });
    defer allocator.free(target_dir);

    log.info("linking files from link/ to repo/{s}/", .{target_name});

    // Walk link directory and create symlinks
    try linkDirectory(allocator, link_dir, target_dir, "");

    // Also link to all worktrees
    const worktree_paths = git.getWorktreePaths(allocator, target_dir) catch |err| {
        if (err == error.FileNotFound) {
            // Not a git repo or no worktrees, skip
            log.info("linking complete", .{});
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

    // Link to each worktree (skip the main repo which is already linked)
    for (worktree_paths) |worktree_path| {
        // Skip if it's not in the repo/ directory (e.g., .git/modules paths for submodules)
        if (!std.mem.startsWith(u8, worktree_path, repo_base)) continue;

        // Skip if it's the same as target_dir
        if (std.mem.eql(u8, worktree_path, target_dir)) continue;

        // Get the worktree name (last component of path)
        const worktree_name = std.fs.path.basename(worktree_path);
        log.info("linking files from link/ to repo/{s}/", .{worktree_name});

        try linkDirectory(allocator, link_dir, worktree_path, "");
    }

    log.info("linking complete", .{});
}

fn linkDirectory(
    allocator: std.mem.Allocator,
    link_base: []const u8,
    target_base: []const u8,
    rel_path: []const u8,
) !void {
    const link_path = if (rel_path.len > 0)
        try std.fs.path.join(allocator, &.{ link_base, rel_path })
    else
        try allocator.dupe(u8, link_base);
    defer allocator.free(link_path);

    var dir = std.fs.cwd().openDir(link_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) {
            log.warn("link directory not found: {s}", .{link_path});
            return;
        }
        return err;
    };
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const new_rel = if (rel_path.len > 0)
            try std.fs.path.join(allocator, &.{ rel_path, entry.name })
        else
            try allocator.dupe(u8, entry.name);
        defer allocator.free(new_rel);

        if (entry.kind == .directory) {
            // Ensure target directory exists
            const target_subdir = try std.fs.path.join(allocator, &.{ target_base, new_rel });
            defer allocator.free(target_subdir);
            std.fs.cwd().makePath(target_subdir) catch |err| {
                if (err != error.PathAlreadyExists) return err;
            };

            try linkDirectory(allocator, link_base, target_base, new_rel);
        } else {
            try linkFile(allocator, link_base, target_base, new_rel);
        }
    }
}

fn linkFile(
    allocator: std.mem.Allocator,
    link_base: []const u8,
    target_base: []const u8,
    rel_path: []const u8,
) !void {
    const link_file = try std.fs.path.join(allocator, &.{ link_base, rel_path });
    defer allocator.free(link_file);

    const target_file = try std.fs.path.join(allocator, &.{ target_base, rel_path });
    defer allocator.free(target_file);

    // Calculate relative path from target to link
    const rel_link = try fs_utils.relativePath(allocator, target_file, link_file);
    defer allocator.free(rel_link);

    // Remove existing file/symlink at target
    std.fs.cwd().deleteFile(target_file) catch |err| {
        if (err != error.FileNotFound) {
            log.warn("could not remove existing {s}: {}", .{ target_file, err });
        }
    };

    // Create symlink
    std.fs.cwd().symLink(rel_link, target_file, .{}) catch |err| {
        log.err("failed to create symlink {s} -> {s}: {}", .{ target_file, rel_link, err });
        return err;
    };

    log.info("linked: {s}", .{rel_path});

    // Add to local git exclude
    try git.addLocalExclude(allocator, target_base, rel_path);
}

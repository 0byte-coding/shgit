const std = @import("std");
const config = @import("../config.zig");
const fs_utils = @import("../fs_utils.zig");
const git = @import("../git.zig");

const log = std.log.scoped(.link);

pub const LinkArgs = struct {
    target: ?[]const u8 = null,
};

pub fn execute(io: std.Io, allocator: std.mem.Allocator, args: LinkArgs, verbose: bool) !void {
    _ = verbose;

    // Find shgit root
    const shgit_root = try config.find_shgit_root(io, allocator) orelse {
        log.err("not in a shgit project (no .shgit directory found)", .{});
        return error.NotShgitProject;
    };
    defer allocator.free(shgit_root);

    log.info("shgit root: {s}", .{shgit_root});

    // Load config
    var cfg = try config.load_config(io, allocator, shgit_root);
    defer cfg.deinit(allocator);

    // Determine target
    const target_name = args.target orelse cfg.main_repo orelse {
        log.err("no target specified and no main_repo in config", .{});
        return error.NoTarget;
    };

    const link_dir = try std.fs.path.join(allocator, &.{ shgit_root, config.LINK_DIR });
    defer allocator.free(link_dir);

    const target_dir = try std.fs.path.join(allocator, &.{ shgit_root, config.REPO_DIR, target_name });
    defer allocator.free(target_dir);

    log.info("linking files from link/ to repo/{s}/", .{target_name});

    // Walk link directory and create symlinks
    try link_directory(io, allocator, link_dir, target_dir, "");

    // Apply remove_patterns to the main repo
    try apply_remove_patterns(io, allocator, target_dir, cfg.remove_patterns);

    // Also link to all worktrees
    const worktree_paths = git.get_worktree_paths(io, allocator, target_dir) catch |err| {
        if (err == error.FileNotFound) {
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
        if (!std.mem.startsWith(u8, worktree_path, repo_base)) continue;
        if (std.mem.eql(u8, worktree_path, target_dir)) continue;

        const worktree_name = std.fs.path.basename(worktree_path);
        log.info("linking files from link/ to repo/{s}/", .{worktree_name});

        try link_directory(io, allocator, link_dir, worktree_path, "");
        try apply_remove_patterns(io, allocator, worktree_path, cfg.remove_patterns);
    }

    log.info("linking complete", .{});
}

/// Remove every file matching any of `patterns` from `repo_base`.
///
/// We only ever consider files that git knows about and does NOT ignore
/// (tracked + untracked-but-not-ignored). This intentionally skips gitignored
/// trees such as `node_modules/`, `dist/`, etc. — shgit should never touch
/// files git itself is ignoring. Tracked matches are additionally marked
/// skip-worktree so the removal is hidden from git status.
fn apply_remove_patterns(
    io: std.Io,
    allocator: std.mem.Allocator,
    repo_base: []const u8,
    patterns: []const []const u8,
) !void {
    if (patterns.len == 0) return;

    const candidates = git.list_non_ignored_files(io, allocator, repo_base) catch |err| {
        log.warn("could not list files for remove_patterns (skipping): {}", .{err});
        return;
    };
    defer {
        for (candidates) |c| allocator.free(c);
        allocator.free(candidates);
    }

    for (candidates) |rel| {
        var matched = false;
        for (patterns) |pat| {
            if (fs_utils.match_glob(rel, pat)) {
                matched = true;
                break;
            }
        }
        if (!matched) continue;

        try remove_matched(io, allocator, repo_base, rel);
    }
}

fn remove_matched(
    io: std.Io,
    allocator: std.mem.Allocator,
    repo_base: []const u8,
    rel_path: []const u8,
) !void {
    // Hide the removal from git for tracked files before deleting it.
    const tracked = git.is_tracked(io, allocator, repo_base, rel_path) catch false;
    if (tracked) {
        git.skip_worktree(io, allocator, repo_base, rel_path) catch |err| {
            log.warn("could not skip-worktree {s}: {}", .{ rel_path, err });
        };
    }

    const target_file = try std.fs.path.join(allocator, &.{ repo_base, rel_path });
    defer allocator.free(target_file);

    std.Io.Dir.cwd().deleteFile(io, target_file) catch |err| {
        if (err == error.FileNotFound) return;
        log.warn("could not remove {s}: {}", .{ target_file, err });
        return;
    };

    log.info("removed: {s}", .{rel_path});
}

fn link_directory(
    io: std.Io,
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

    var dir = std.Io.Dir.cwd().openDir(io, link_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) {
            log.warn("link directory not found: {s}", .{link_path});
            return;
        }
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
            const target_subdir = try std.fs.path.join(allocator, &.{ target_base, new_rel });
            defer allocator.free(target_subdir);
            std.Io.Dir.cwd().createDirPath(io, target_subdir) catch |err| {
                if (err != error.PathAlreadyExists) return err;
            };
            try link_directory(io, allocator, link_base, target_base, new_rel);
        } else {
            try link_single_file(io, allocator, link_base, target_base, new_rel);
        }
    }
}

fn link_single_file(
    io: std.Io,
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
    const rel_link = try fs_utils.relative_path(allocator, target_file, link_file);
    defer allocator.free(rel_link);

    // Determine whether the target repo already tracks this file. If so, we
    // shadow it: set skip-worktree *before* swapping the file so git does not
    // report the symlink as a modification. Otherwise we fall back to the local
    // exclude mechanism for untracked files.
    const tracked = git.is_tracked(io, allocator, target_base, rel_path) catch false;
    if (tracked) {
        git.skip_worktree(io, allocator, target_base, rel_path) catch |err| {
            log.warn("could not shadow tracked file {s}: {}", .{ rel_path, err });
        };
    }

    // Remove existing file/symlink at target
    std.Io.Dir.cwd().deleteFile(io, target_file) catch |err| {
        if (err != error.FileNotFound) {
            log.warn("could not remove existing {s}: {}", .{ target_file, err });
        }
    };

    // Create symlink
    std.Io.Dir.cwd().symLink(io, rel_link, target_file, .{}) catch |err| {
        log.err("failed to create symlink {s} -> {s}: {}", .{ target_file, rel_link, err });
        return err;
    };

    log.info("linked: {s}", .{rel_path});

    // For untracked files, add to local git exclude so the new symlink is ignored.
    if (!tracked) {
        try git.add_local_exclude(io, allocator, target_base, rel_path);
    }
}

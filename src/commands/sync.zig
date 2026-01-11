const std = @import("std");
const config = @import("../config.zig");
const fs_utils = @import("../fs_utils.zig");

const log = std.log.scoped(.sync);

pub fn execute(allocator: std.mem.Allocator, verbose: bool) !void {
    _ = verbose;

    const shgit_root = try config.findShgitRoot(allocator) orelse {
        log.err("not in a shgit project", .{});
        return error.NotShgitProject;
    };
    defer allocator.free(shgit_root);

    var cfg = try config.loadConfig(allocator, shgit_root);
    defer cfg.deinit(allocator);

    if (cfg.sync_patterns.len == 0) {
        log.info("no sync_patterns configured in .shgit/config.zon", .{});
        return;
    }

    const main_repo = cfg.main_repo orelse {
        log.err("no main_repo in config", .{});
        return error.NoMainRepo;
    };

    const repo_dir = try std.fs.path.join(allocator, &.{ shgit_root, config.REPO_DIR });
    defer allocator.free(repo_dir);

    const main_repo_path = try std.fs.path.join(allocator, &.{ repo_dir, main_repo });
    defer allocator.free(main_repo_path);

    // Find all worktrees (directories in repo/ that aren't the main repo)
    var dir = std.fs.cwd().openDir(repo_dir, .{ .iterate = true }) catch |err| {
        log.err("could not open repo directory: {}", .{err});
        return err;
    };
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;
        if (std.mem.eql(u8, entry.name, main_repo)) continue;

        const worktree_path = try std.fs.path.join(allocator, &.{ repo_dir, entry.name });
        defer allocator.free(worktree_path);

        log.info("syncing to {s}", .{entry.name});

        for (cfg.sync_patterns) |pattern| {
            try syncPattern(allocator, main_repo_path, worktree_path, pattern);
        }
    }

    log.info("sync complete", .{});
}

fn syncPattern(
    allocator: std.mem.Allocator,
    main_repo_path: []const u8,
    worktree_path: []const u8,
    pattern: []const u8,
) !void {
    try walkAndSync(allocator, main_repo_path, worktree_path, "", pattern);
}

fn walkAndSync(
    allocator: std.mem.Allocator,
    main_base: []const u8,
    worktree_base: []const u8,
    rel_path: []const u8,
    pattern: []const u8,
) !void {
    const main_path = if (rel_path.len > 0)
        try std.fs.path.join(allocator, &.{ main_base, rel_path })
    else
        try allocator.dupe(u8, main_base);
    defer allocator.free(main_path);

    var dir = std.fs.cwd().openDir(main_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound or err == error.NotDir) return;
        return err;
    };
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (std.mem.eql(u8, entry.name, ".git")) continue;

        const new_rel = if (rel_path.len > 0)
            try std.fs.path.join(allocator, &.{ rel_path, entry.name })
        else
            try allocator.dupe(u8, entry.name);
        defer allocator.free(new_rel);

        if (entry.kind == .directory) {
            try walkAndSync(allocator, main_base, worktree_base, new_rel, pattern);
        } else {
            if (matchesPattern(new_rel, pattern) or matchesPattern(entry.name, pattern)) {
                const src = try std.fs.path.join(allocator, &.{ main_base, new_rel });
                defer allocator.free(src);

                const dst = try std.fs.path.join(allocator, &.{ worktree_base, new_rel });
                defer allocator.free(dst);

                const rel_link = try fs_utils.relativePath(allocator, dst, src);
                defer allocator.free(rel_link);

                if (std.fs.path.dirname(dst)) |parent| {
                    std.fs.cwd().makePath(parent) catch {};
                }

                std.fs.cwd().deleteFile(dst) catch {};
                std.fs.cwd().symLink(rel_link, dst, .{}) catch |err| {
                    log.warn("could not sync {s}: {}", .{ new_rel, err });
                    continue;
                };

                log.info("synced: {s}", .{new_rel});
            }
        }
    }
}

fn matchesPattern(path: []const u8, pattern: []const u8) bool {
    if (std.mem.eql(u8, path, pattern)) return true;
    const filename = std.fs.path.basename(path);
    if (std.mem.eql(u8, filename, pattern)) return true;
    if (std.mem.endsWith(u8, path, pattern)) return true;
    return false;
}

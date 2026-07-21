const std = @import("std");
const config = @import("../config.zig");
const fs_utils = @import("../fs_utils.zig");
const git = @import("../git.zig");

const log = std.log.scoped(.sync);

pub fn execute(io: std.Io, allocator: std.mem.Allocator, verbose: bool) !void {
    _ = verbose;

    const shgit_root = try config.findShgitRoot(io, allocator) orelse {
        log.err("not in a shgit project", .{});
        return error.NotShgitProject;
    };
    defer allocator.free(shgit_root);

    var cfg = try config.loadConfig(io, allocator, shgit_root);
    defer cfg.deinit(allocator);

    if (!cfg.sync_enabled) {
        log.info("sync is disabled in config (sync_enabled = false)", .{});
        return;
    }

    if (cfg.sync_patterns.len == 0) {
        log.info("no sync_patterns configured in .shgit/config.json", .{});
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

    var dir = std.Io.Dir.cwd().openDir(io, repo_dir, .{ .iterate = true }) catch |err| {
        log.err("could not open repo directory: {}", .{err});
        return err;
    };
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (std.mem.eql(u8, entry.name, main_repo)) continue;

        const worktree_path = try std.fs.path.join(allocator, &.{ repo_dir, entry.name });
        defer allocator.free(worktree_path);

        log.info("syncing to {s}", .{entry.name});

        for (cfg.sync_patterns) |sp| {
            try syncPattern(io, allocator, main_repo_path, worktree_path, sp.pattern, sp.mode);
        }
    }

    log.info("sync complete", .{});
}

fn syncPattern(
    io: std.Io,
    allocator: std.mem.Allocator,
    main_repo_path: []const u8,
    worktree_path: []const u8,
    pattern: []const u8,
    mode: config.SyncMode,
) !void {
    try walkAndSync(io, allocator, main_repo_path, worktree_path, "", pattern, mode);
}

fn walkAndSync(
    io: std.Io,
    allocator: std.mem.Allocator,
    main_base: []const u8,
    worktree_base: []const u8,
    rel_path: []const u8,
    pattern: []const u8,
    mode: config.SyncMode,
) !void {
    const main_path = if (rel_path.len > 0)
        try std.fs.path.join(allocator, &.{ main_base, rel_path })
    else
        try allocator.dupe(u8, main_base);
    defer allocator.free(main_path);

    var dir = std.Io.Dir.cwd().openDir(io, main_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound or err == error.NotDir) return;
        return err;
    };
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (std.mem.eql(u8, entry.name, ".git")) continue;

        const new_rel = if (rel_path.len > 0)
            try std.fs.path.join(allocator, &.{ rel_path, entry.name })
        else
            try allocator.dupe(u8, entry.name);
        defer allocator.free(new_rel);

        if (entry.kind == .directory) {
            try walkAndSync(io, allocator, main_base, worktree_base, new_rel, pattern, mode);
        } else {
            if (fs_utils.matchGlob(new_rel, pattern)) {
                const src = try std.fs.path.join(allocator, &.{ main_base, new_rel });
                defer allocator.free(src);

                const dst = try std.fs.path.join(allocator, &.{ worktree_base, new_rel });
                defer allocator.free(dst);

                if (std.fs.path.dirname(dst)) |parent| {
                    std.Io.Dir.cwd().createDirPath(io, parent) catch {};
                }

                std.Io.Dir.cwd().deleteFile(io, dst) catch {};

                switch (mode) {
                    .symlink => {
                        const rel_link = try fs_utils.relativePath(allocator, dst, src);
                        defer allocator.free(rel_link);

                        std.Io.Dir.cwd().symLink(io, rel_link, dst, .{}) catch |err| {
                            log.warn("could not symlink {s}: {}", .{ new_rel, err });
                            continue;
                        };
                        log.info("symlinked: {s}", .{new_rel});
                    },
                    .copy => {
                        std.Io.Dir.copyFile(.cwd(), src, .cwd(), dst, io, .{}) catch |err| {
                            log.warn("could not copy {s}: {}", .{ new_rel, err });
                            continue;
                        };
                        log.info("copied: {s}", .{new_rel});
                    },
                }

                git.addLocalExclude(io, allocator, worktree_base, new_rel) catch |err| {
                    log.warn("could not add {s} to local exclude: {}", .{ new_rel, err });
                };
            }
        }
    }
}

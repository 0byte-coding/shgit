const std = @import("std");
const config = @import("config.zig");
const fs_utils = @import("fs_utils.zig");
const git = @import("git.zig");

const log = std.log.scoped(.sync);

/// Propagate files from the main repo into a worktree according to the config's
/// sync patterns. Each matching file is symlinked or copied (per pattern mode)
/// and added to the worktree's local git exclude.
///
/// This is invoked automatically when a worktree is created (`shgit worktree add`).
pub fn syncToWorktree(
    io: std.Io,
    allocator: std.mem.Allocator,
    cfg: config.Config,
    main_repo_path: []const u8,
    worktree_path: []const u8,
) !void {
    if (!cfg.sync_enabled) return;
    for (cfg.sync_patterns) |sp| {
        try walkAndSync(io, allocator, main_repo_path, worktree_path, "", sp.pattern, sp.mode);
    }
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

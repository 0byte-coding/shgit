const std = @import("std");
const config = @import("../config.zig");
const git = @import("../git.zig");
const fs_utils = @import("../fs_utils.zig");

const log = std.log.scoped(.worktree);

pub const WorktreeAddArgs = struct {
    name: []const u8,
    commitish: []const u8,
    new_branch: ?[]const u8 = null,
};

pub const WorktreeRemoveArgs = struct {
    name: []const u8,
};

pub fn executeAdd(io: std.Io, allocator: std.mem.Allocator, args: WorktreeAddArgs, verbose: bool) !void {
    _ = verbose;

    const name = args.name;
    const commitish = args.commitish;
    const new_branch = args.new_branch;

    const branch: []const u8 = if (new_branch) |nb| nb else commitish;
    const create_branch = new_branch != null;
    const start_point = if (new_branch != null) commitish else null;

    const shgit_root = try config.findShgitRoot(io, allocator) orelse {
        log.err("not in a shgit project", .{});
        return error.NotShgitProject;
    };
    defer allocator.free(shgit_root);

    var cfg = try config.loadConfig(io, allocator, shgit_root);
    defer cfg.deinit(allocator);

    const main_repo = cfg.main_repo orelse {
        log.err("no main_repo in config", .{});
        return error.NoMainRepo;
    };

    const main_repo_path = try std.fs.path.join(allocator, &.{ shgit_root, config.REPO_DIR, main_repo });
    defer allocator.free(main_repo_path);

    const worktree_path = try std.fs.path.join(allocator, &.{ shgit_root, config.REPO_DIR, name });
    defer allocator.free(worktree_path);

    try git.addWorktree(io, allocator, main_repo_path, worktree_path, branch, create_branch, start_point);

    const link_dir = try std.fs.path.join(allocator, &.{ shgit_root, config.LINK_DIR });
    defer allocator.free(link_dir);

    try linkToWorktree(io, allocator, link_dir, worktree_path, "");

    if (cfg.sync_enabled) {
        try syncEnvFiles(io, allocator, cfg, main_repo_path, worktree_path);
    }

    log.info("worktree created at repo/{s}/", .{name});
}

pub fn executeRemove(io: std.Io, allocator: std.mem.Allocator, args: WorktreeRemoveArgs, verbose: bool) !void {
    _ = verbose;

    const name = args.name;

    const shgit_root = try config.findShgitRoot(io, allocator) orelse {
        log.err("not in a shgit project", .{});
        return error.NotShgitProject;
    };
    defer allocator.free(shgit_root);

    var cfg = try config.loadConfig(io, allocator, shgit_root);
    defer cfg.deinit(allocator);

    const main_repo = cfg.main_repo orelse {
        log.err("no main_repo in config", .{});
        return error.NoMainRepo;
    };

    if (std.mem.eql(u8, name, main_repo)) {
        log.err("cannot remove main repo worktree", .{});
        return error.CannotRemoveMain;
    }

    const main_repo_path = try std.fs.path.join(allocator, &.{ shgit_root, config.REPO_DIR, main_repo });
    defer allocator.free(main_repo_path);

    const worktree_path = try std.fs.path.join(allocator, &.{ shgit_root, config.REPO_DIR, name });
    defer allocator.free(worktree_path);

    try git.removeWorktree(io, allocator, main_repo_path, worktree_path);

    log.info("removed worktree '{s}'", .{name});
}

pub fn executeList(io: std.Io, allocator: std.mem.Allocator, verbose: bool) !void {
    _ = verbose;
    const shgit_root = try config.findShgitRoot(io, allocator) orelse {
        log.err("not in a shgit project", .{});
        return error.NotShgitProject;
    };
    defer allocator.free(shgit_root);

    var cfg = try config.loadConfig(io, allocator, shgit_root);
    defer cfg.deinit(allocator);

    const main_repo = cfg.main_repo orelse {
        log.err("no main_repo in config", .{});
        return error.NoMainRepo;
    };

    const main_repo_path = try std.fs.path.join(allocator, &.{ shgit_root, config.REPO_DIR, main_repo });
    defer allocator.free(main_repo_path);

    try git.listWorktrees(io, allocator, main_repo_path);
}

fn linkToWorktree(
    io: std.Io,
    allocator: std.mem.Allocator,
    link_base: []const u8,
    worktree_base: []const u8,
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
            const target_subdir = try std.fs.path.join(allocator, &.{ worktree_base, new_rel });
            defer allocator.free(target_subdir);
            std.Io.Dir.cwd().createDirPath(io, target_subdir) catch |err| {
                if (err != error.PathAlreadyExists) return err;
            };
            try linkToWorktree(io, allocator, link_base, worktree_base, new_rel);
        } else {
            const link_file = try std.fs.path.join(allocator, &.{ link_base, new_rel });
            defer allocator.free(link_file);

            const target_file = try std.fs.path.join(allocator, &.{ worktree_base, new_rel });
            defer allocator.free(target_file);

            const rel_link = try fs_utils.relativePath(allocator, target_file, link_file);
            defer allocator.free(rel_link);

            std.Io.Dir.cwd().deleteFile(io, target_file) catch {};
            try std.Io.Dir.cwd().symLink(io, rel_link, target_file, .{});
            try git.addLocalExclude(io, allocator, worktree_base, new_rel);

            log.info("linked: {s}", .{new_rel});
        }
    }
}

fn syncEnvFiles(
    io: std.Io,
    allocator: std.mem.Allocator,
    cfg: config.Config,
    main_repo_path: []const u8,
    worktree_path: []const u8,
) !void {
    for (cfg.sync_patterns) |sp| {
        try syncPattern(io, allocator, main_repo_path, worktree_path, sp.pattern, sp.mode);
    }
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
            if (matchesPattern(new_rel, pattern) or matchesPattern(entry.name, pattern)) {
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

fn matchesPattern(path: []const u8, pattern: []const u8) bool {
    if (std.mem.eql(u8, path, pattern)) return true;
    const filename = std.fs.path.basename(path);
    if (std.mem.eql(u8, filename, pattern)) return true;
    if (std.mem.endsWith(u8, path, pattern)) return true;
    return false;
}

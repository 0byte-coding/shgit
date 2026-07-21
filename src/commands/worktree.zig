const std = @import("std");
const config = @import("../config.zig");
const git = @import("../git.zig");
const fs_utils = @import("../fs_utils.zig");
const sync_files = @import("../sync_files.zig");

const log = std.log.scoped(.worktree);

pub const WorktreeAddArgs = struct {
    name: []const u8,
    commitish: []const u8,
    new_branch: ?[]const u8 = null,
};

pub const WorktreeRemoveArgs = struct {
    name: []const u8,
    force: bool = false,
};

pub fn execute_add(io: std.Io, allocator: std.mem.Allocator, args: WorktreeAddArgs, verbose: bool) !void {
    _ = verbose;

    const name = args.name;
    const commitish = args.commitish;
    const new_branch = args.new_branch;

    const branch: []const u8 = if (new_branch) |nb| nb else commitish;
    const create_branch = new_branch != null;
    const start_point = if (new_branch != null) commitish else null;

    const shgit_root = try config.find_shgit_root(io, allocator) orelse {
        log.err("not in a shgit project", .{});
        return error.NotShgitProject;
    };
    defer allocator.free(shgit_root);

    var cfg = try config.load_config(io, allocator, shgit_root);
    defer cfg.deinit(allocator);

    const main_repo = cfg.main_repo orelse {
        log.err("no main_repo in config", .{});
        return error.NoMainRepo;
    };

    const main_repo_path = try std.fs.path.join(allocator, &.{ shgit_root, config.REPO_DIR, main_repo });
    defer allocator.free(main_repo_path);

    const worktree_path = try std.fs.path.join(allocator, &.{ shgit_root, config.REPO_DIR, name });
    defer allocator.free(worktree_path);

    try git.add_worktree(io, allocator, main_repo_path, worktree_path, branch, create_branch, start_point);

    const link_dir = try std.fs.path.join(allocator, &.{ shgit_root, config.LINK_DIR });
    defer allocator.free(link_dir);

    try link_to_worktree(io, allocator, link_dir, worktree_path, "");

    try sync_files.sync_to_worktree(io, allocator, cfg, main_repo_path, worktree_path);

    log.info("worktree created at repo/{s}/", .{name});
}

pub fn execute_remove(io: std.Io, allocator: std.mem.Allocator, args: WorktreeRemoveArgs, verbose: bool) !void {
    _ = verbose;

    const name = args.name;

    const shgit_root = try config.find_shgit_root(io, allocator) orelse {
        log.err("not in a shgit project", .{});
        return error.NotShgitProject;
    };
    defer allocator.free(shgit_root);

    var cfg = try config.load_config(io, allocator, shgit_root);
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

    try git.remove_worktree(io, allocator, main_repo_path, worktree_path, args.force);

    log.info("removed worktree '{s}'", .{name});
}

pub fn execute_prune(io: std.Io, allocator: std.mem.Allocator, verbose: bool) !void {
    _ = verbose;
    const shgit_root = try config.find_shgit_root(io, allocator) orelse {
        log.err("not in a shgit project", .{});
        return error.NotShgitProject;
    };
    defer allocator.free(shgit_root);

    var cfg = try config.load_config(io, allocator, shgit_root);
    defer cfg.deinit(allocator);

    const main_repo = cfg.main_repo orelse {
        log.err("no main_repo in config", .{});
        return error.NoMainRepo;
    };

    const main_repo_path = try std.fs.path.join(allocator, &.{ shgit_root, config.REPO_DIR, main_repo });
    defer allocator.free(main_repo_path);

    try git.prune_worktrees(io, allocator, main_repo_path);

    log.info("pruned stale worktree metadata", .{});
}

pub fn execute_list(io: std.Io, allocator: std.mem.Allocator, verbose: bool) !void {
    _ = verbose;
    const shgit_root = try config.find_shgit_root(io, allocator) orelse {
        log.err("not in a shgit project", .{});
        return error.NotShgitProject;
    };
    defer allocator.free(shgit_root);

    var cfg = try config.load_config(io, allocator, shgit_root);
    defer cfg.deinit(allocator);

    const main_repo = cfg.main_repo orelse {
        log.err("no main_repo in config", .{});
        return error.NoMainRepo;
    };

    const main_repo_path = try std.fs.path.join(allocator, &.{ shgit_root, config.REPO_DIR, main_repo });
    defer allocator.free(main_repo_path);

    try git.list_worktrees(io, allocator, main_repo_path);
}

fn link_to_worktree(
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
            try link_to_worktree(io, allocator, link_base, worktree_base, new_rel);
        } else {
            const link_file = try std.fs.path.join(allocator, &.{ link_base, new_rel });
            defer allocator.free(link_file);

            const target_file = try std.fs.path.join(allocator, &.{ worktree_base, new_rel });
            defer allocator.free(target_file);

            const rel_link = try fs_utils.relative_path(allocator, target_file, link_file);
            defer allocator.free(rel_link);

            std.Io.Dir.cwd().deleteFile(io, target_file) catch {};
            try std.Io.Dir.cwd().symLink(io, rel_link, target_file, .{});
            try git.add_local_exclude(io, allocator, worktree_base, new_rel);

            log.info("linked: {s}", .{new_rel});
        }
    }
}



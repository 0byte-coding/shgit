const std = @import("std");
const config = @import("../config.zig");
const git = @import("../git.zig");
const fs_utils = @import("../fs_utils.zig");
const link_cmd = @import("link.zig");

const log = std.log.scoped(.worktree);

pub fn execute(allocator: std.mem.Allocator, args: anytype, verbose: bool) !void {
    _ = verbose;

    if (args.subcommands_opt) |sub| {
        switch (sub) {
            .add => |add_args| try executeAdd(allocator, add_args),
            .remove => |remove_args| try executeRemove(allocator, remove_args),
            .list => try executeList(allocator),
        }
    } else {
        log.err("no worktree subcommand specified", .{});
        return error.NoSubcommand;
    }
}

fn executeAdd(allocator: std.mem.Allocator, args: anytype) !void {
    const name = args.positionals.NAME;
    const branch = args.options.branch orelse name;

    const shgit_root = try config.findShgitRoot(allocator) orelse {
        log.err("not in a shgit project", .{});
        return error.NotShgitProject;
    };
    defer allocator.free(shgit_root);

    var cfg = try config.loadConfig(allocator, shgit_root);
    defer cfg.deinit(allocator);

    const main_repo = cfg.main_repo orelse {
        log.err("no main_repo in config", .{});
        return error.NoMainRepo;
    };

    const main_repo_path = try std.fs.path.join(allocator, &.{ shgit_root, config.REPO_DIR, main_repo });
    defer allocator.free(main_repo_path);

    const worktree_path = try std.fs.path.join(allocator, &.{ shgit_root, config.REPO_DIR, name });
    defer allocator.free(worktree_path);

    log.info("creating worktree '{s}' with branch '{s}'", .{ name, branch });

    // Create git worktree
    try git.addWorktree(allocator, main_repo_path, worktree_path, branch);

    // Link files from link/ to new worktree
    const link_dir = try std.fs.path.join(allocator, &.{ shgit_root, config.LINK_DIR });
    defer allocator.free(link_dir);

    try linkToWorktree(allocator, link_dir, worktree_path, "");

    // Sync env files if configured
    try syncEnvFiles(allocator, cfg, main_repo_path, worktree_path);

    log.info("worktree created at repo/{s}/", .{name});
}

fn executeRemove(allocator: std.mem.Allocator, args: anytype) !void {
    const name = args.positionals.NAME;

    const shgit_root = try config.findShgitRoot(allocator) orelse {
        log.err("not in a shgit project", .{});
        return error.NotShgitProject;
    };
    defer allocator.free(shgit_root);

    var cfg = try config.loadConfig(allocator, shgit_root);
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

    try git.removeWorktree(allocator, main_repo_path, worktree_path);

    log.info("removed worktree '{s}'", .{name});
}

fn executeList(allocator: std.mem.Allocator) !void {
    const shgit_root = try config.findShgitRoot(allocator) orelse {
        log.err("not in a shgit project", .{});
        return error.NotShgitProject;
    };
    defer allocator.free(shgit_root);

    var cfg = try config.loadConfig(allocator, shgit_root);
    defer cfg.deinit(allocator);

    const main_repo = cfg.main_repo orelse {
        log.err("no main_repo in config", .{});
        return error.NoMainRepo;
    };

    const main_repo_path = try std.fs.path.join(allocator, &.{ shgit_root, config.REPO_DIR, main_repo });
    defer allocator.free(main_repo_path);

    try git.listWorktrees(allocator, main_repo_path);
}

fn linkToWorktree(
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

    var dir = std.fs.cwd().openDir(link_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return;
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
            const target_subdir = try std.fs.path.join(allocator, &.{ worktree_base, new_rel });
            defer allocator.free(target_subdir);
            std.fs.cwd().makePath(target_subdir) catch |err| {
                if (err != error.PathAlreadyExists) return err;
            };
            try linkToWorktree(allocator, link_base, worktree_base, new_rel);
        } else {
            const link_file = try std.fs.path.join(allocator, &.{ link_base, new_rel });
            defer allocator.free(link_file);

            const target_file = try std.fs.path.join(allocator, &.{ worktree_base, new_rel });
            defer allocator.free(target_file);

            const rel_link = try fs_utils.relativePath(allocator, target_file, link_file);
            defer allocator.free(rel_link);

            std.fs.cwd().deleteFile(target_file) catch {};
            try std.fs.cwd().symLink(rel_link, target_file, .{});
            try git.addLocalExclude(allocator, worktree_base, new_rel);

            log.info("linked: {s}", .{new_rel});
        }
    }
}

fn syncEnvFiles(
    allocator: std.mem.Allocator,
    cfg: config.Config,
    main_repo_path: []const u8,
    worktree_path: []const u8,
) !void {
    for (cfg.sync_patterns) |pattern| {
        try syncPattern(allocator, main_repo_path, worktree_path, pattern);
    }
}

fn syncPattern(
    allocator: std.mem.Allocator,
    main_repo_path: []const u8,
    worktree_path: []const u8,
    pattern: []const u8,
) !void {
    // Simple pattern matching - walk main repo and find matches
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
        // Skip .git
        if (std.mem.eql(u8, entry.name, ".git")) continue;

        const new_rel = if (rel_path.len > 0)
            try std.fs.path.join(allocator, &.{ rel_path, entry.name })
        else
            try allocator.dupe(u8, entry.name);
        defer allocator.free(new_rel);

        if (entry.kind == .directory) {
            try walkAndSync(allocator, main_base, worktree_base, new_rel, pattern);
        } else {
            // Check if matches pattern
            if (matchesPattern(new_rel, pattern) or matchesPattern(entry.name, pattern)) {
                const src = try std.fs.path.join(allocator, &.{ main_base, new_rel });
                defer allocator.free(src);

                const dst = try std.fs.path.join(allocator, &.{ worktree_base, new_rel });
                defer allocator.free(dst);

                const rel_link = try fs_utils.relativePath(allocator, dst, src);
                defer allocator.free(rel_link);

                // Ensure parent dir exists
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
    // Simple pattern matching:
    // - Exact match
    // - Pattern matches filename
    // - Pattern matches end of path

    if (std.mem.eql(u8, path, pattern)) return true;

    // Get filename from path
    const filename = std.fs.path.basename(path);
    if (std.mem.eql(u8, filename, pattern)) return true;

    // Check if path ends with pattern (for paths like "src/folder/file")
    if (std.mem.endsWith(u8, path, pattern)) return true;

    return false;
}

test "matchesPattern" {
    try std.testing.expect(matchesPattern(".env", ".env"));
    try std.testing.expect(matchesPattern("src/.env", ".env"));
    try std.testing.expect(matchesPattern(".env.local", ".env.local"));
    try std.testing.expect(!matchesPattern(".env.local", ".env"));
    try std.testing.expect(matchesPattern("src/config/.env", ".env"));
}

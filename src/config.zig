const std = @import("std");

const log = std.log.scoped(.config);

/// How to sync a file: symlink or copy
pub const SyncMode = enum {
    symlink,
    copy,
};

/// A sync pattern with its mode
pub const SyncPattern = struct {
    pattern: []const u8,
    mode: SyncMode = .symlink,
};

pub const Config = struct {
    /// Patterns for files to sync from main repo to worktrees (like .gitignore patterns)
    sync_patterns: []const SyncPattern = &.{},
    /// Main repo directory name (default: first directory in repo/)
    main_repo: ?[]const u8 = null,
    /// Whether sync_patterns feature is enabled (default: true)
    sync_enabled: bool = true,

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        for (self.sync_patterns) |sp| {
            allocator.free(sp.pattern);
        }
        if (self.sync_patterns.len > 0) {
            allocator.free(self.sync_patterns);
        }
        if (self.main_repo) |repo| {
            allocator.free(repo);
        }
        self.* = .{};
    }
};

pub const SHGIT_DIR = ".shgit";
pub const CONFIG_FILE = "config.json";
pub const LINK_DIR = "link";
pub const REPO_DIR = "repo";

/// Find the shgit root directory by looking for .shgit folder
pub fn findShgitRoot(io: std.Io, allocator: std.mem.Allocator) !?[]const u8 {
    var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = std.Io.Dir.cwd().realPathFile(io, ".", &cwd_buf) catch |err| {
        log.err("failed to get cwd: {}", .{err});
        return null;
    };
    const cwd = cwd_buf[0..n];

    var path = try allocator.dupe(u8, cwd);
    defer allocator.free(path);

    while (true) {
        const shgit_path = try std.fs.path.join(allocator, &.{ path, SHGIT_DIR });
        defer allocator.free(shgit_path);

        if (std.Io.Dir.cwd().statFile(io, shgit_path, .{})) |stat| {
            if (stat.kind == .directory) {
                return try allocator.dupe(u8, path);
            }
        } else |_| {}

        const parent = std.fs.path.dirname(path);
        if (parent == null or std.mem.eql(u8, parent.?, path)) {
            return null;
        }
        const old_path = path;
        path = try allocator.dupe(u8, parent.?);
        allocator.free(old_path);
    }
}

/// Load config from .shgit/config.json
pub fn loadConfig(io: std.Io, allocator: std.mem.Allocator, shgit_root: []const u8) !Config {
    const config_path = try std.fs.path.join(allocator, &.{ shgit_root, SHGIT_DIR, CONFIG_FILE });
    defer allocator.free(config_path);

    const file = std.Io.Dir.cwd().openFile(io, config_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            log.debug("no config file found, using defaults", .{});
            return Config{};
        }
        return err;
    };
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var r = file.reader(io, &buf);
    const content = try r.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(content);

    return parseConfig(allocator, content);
}

pub fn parseConfig(allocator: std.mem.Allocator, content: []const u8) !Config {
    const parsed = try std.json.parseFromSlice(Config, allocator, content, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    // Deep copy the parsed config since parsed.deinit() will free it
    var cfg = Config{
        .sync_enabled = parsed.value.sync_enabled,
    };

    if (parsed.value.main_repo) |repo| {
        cfg.main_repo = try allocator.dupe(u8, repo);
    }

    if (parsed.value.sync_patterns.len > 0) {
        const patterns = try allocator.alloc(SyncPattern, parsed.value.sync_patterns.len);
        for (parsed.value.sync_patterns, 0..) |sp, i| {
            patterns[i] = .{
                .pattern = try allocator.dupe(u8, sp.pattern),
                .mode = sp.mode,
            };
        }
        cfg.sync_patterns = patterns;
    }

    return cfg;
}

/// Save config to .shgit/config.json
pub fn saveConfig(io: std.Io, allocator: std.mem.Allocator, shgit_root: []const u8, cfg: Config) !void {
    const dir_path = try std.fs.path.join(allocator, &.{ shgit_root, SHGIT_DIR });
    defer allocator.free(dir_path);

    std.Io.Dir.cwd().createDirPath(io, dir_path) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    const config_path = try std.fs.path.join(allocator, &.{ shgit_root, SHGIT_DIR, CONFIG_FILE });
    defer allocator.free(config_path);

    const file = try std.Io.Dir.cwd().createFile(io, config_path, .{});
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var file_writer = file.writer(io, &buf);
    const writer = &file_writer.interface;

    try writer.print("{f}", .{std.json.fmt(cfg, .{ .whitespace = .indent_2 })});
    try writer.flush();

    log.info("saved config to {s}", .{config_path});
}

/// Create initial shgit directory structure
pub fn initShgitStructure(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
    // Create .shgit/
    const shgit_dir = try std.fs.path.join(allocator, &.{ path, SHGIT_DIR });
    defer allocator.free(shgit_dir);
    try std.Io.Dir.cwd().createDirPath(io, shgit_dir);

    // Create link/
    const link_dir = try std.fs.path.join(allocator, &.{ path, LINK_DIR });
    defer allocator.free(link_dir);
    try std.Io.Dir.cwd().createDirPath(io, link_dir);

    // Create repo/
    const repo_dir = try std.fs.path.join(allocator, &.{ path, REPO_DIR });
    defer allocator.free(repo_dir);
    try std.Io.Dir.cwd().createDirPath(io, repo_dir);

    log.info("created shgit structure at {s}", .{path});
}

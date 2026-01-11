const std = @import("std");

const log = std.log.scoped(.config);

pub const Config = struct {
    /// Patterns for files to sync from main repo to worktrees (like .gitignore patterns)
    sync_patterns: []const []const u8 = &.{},
    /// Main repo directory name (default: first directory in repo/)
    main_repo: ?[]const u8 = null,

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        for (self.sync_patterns) |pattern| {
            allocator.free(pattern);
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
pub const CONFIG_FILE = "config.zon";
pub const LINK_DIR = "link";
pub const REPO_DIR = "repo";

/// Find the shgit root directory by looking for .shgit folder
pub fn findShgitRoot(allocator: std.mem.Allocator) !?[]const u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.fs.cwd().realpath(".", &cwd_buf) catch |err| {
        log.err("failed to get cwd: {}", .{err});
        return null;
    };

    var path = try allocator.dupe(u8, cwd);
    defer allocator.free(path);

    while (true) {
        const shgit_path = try std.fs.path.join(allocator, &.{ path, SHGIT_DIR });
        defer allocator.free(shgit_path);

        if (std.fs.cwd().statFile(shgit_path)) |stat| {
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

/// Load config from .shgit/config.zon
pub fn loadConfig(allocator: std.mem.Allocator, shgit_root: []const u8) !Config {
    const config_path = try std.fs.path.join(allocator, &.{ shgit_root, SHGIT_DIR, CONFIG_FILE });
    defer allocator.free(config_path);

    const file = std.fs.cwd().openFile(config_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            log.debug("no config file found, using defaults", .{});
            return Config{};
        }
        return err;
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    return parseConfig(allocator, content);
}

fn parseConfig(allocator: std.mem.Allocator, content: []const u8) !Config {
    // Simple ZON-like parsing for sync_patterns
    var cfg = Config{};
    var patterns: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (patterns.items) |p| allocator.free(p);
        patterns.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, content, '\n');
    var in_sync_patterns = false;

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");

        if (std.mem.startsWith(u8, trimmed, ".sync_patterns")) {
            in_sync_patterns = true;
            continue;
        }

        if (in_sync_patterns) {
            if (std.mem.startsWith(u8, trimmed, "},") or std.mem.eql(u8, trimmed, "}")) {
                in_sync_patterns = false;
                continue;
            }

            // Parse quoted string like "pattern",
            if (std.mem.startsWith(u8, trimmed, "\"")) {
                const end = std.mem.indexOfScalarPos(u8, trimmed, 1, '"') orelse continue;
                const pattern = try allocator.dupe(u8, trimmed[1..end]);
                try patterns.append(allocator, pattern);
            }
        }

        if (std.mem.startsWith(u8, trimmed, ".main_repo")) {
            // Parse .main_repo = "name",
            const eq_pos = std.mem.indexOf(u8, trimmed, "=") orelse continue;
            const rest = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t");
            if (std.mem.startsWith(u8, rest, "\"")) {
                const end = std.mem.indexOfScalarPos(u8, rest, 1, '"') orelse continue;
                cfg.main_repo = try allocator.dupe(u8, rest[1..end]);
            }
        }
    }

    cfg.sync_patterns = try patterns.toOwnedSlice(allocator);
    return cfg;
}

/// Save config to .shgit/config.zon
pub fn saveConfig(allocator: std.mem.Allocator, shgit_root: []const u8, cfg: Config) !void {
    const dir_path = try std.fs.path.join(allocator, &.{ shgit_root, SHGIT_DIR });
    defer allocator.free(dir_path);

    std.fs.cwd().makePath(dir_path) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    const config_path = try std.fs.path.join(allocator, &.{ shgit_root, SHGIT_DIR, CONFIG_FILE });
    defer allocator.free(config_path);

    const file = try std.fs.cwd().createFile(config_path, .{});
    defer file.close();

    var buf: [4096]u8 = undefined;
    var file_writer = file.writer(&buf);
    const writer = &file_writer.interface;
    try writer.writeAll(".{\n");

    if (cfg.main_repo) |repo| {
        try writer.print("    .main_repo = \"{s}\",\n", .{repo});
    }

    try writer.writeAll("    .sync_patterns = .{\n");
    for (cfg.sync_patterns) |pattern| {
        try writer.print("        \"{s}\",\n", .{pattern});
    }
    try writer.writeAll("    },\n");
    try writer.writeAll("}\n");
    try writer.flush();

    log.info("saved config to {s}", .{config_path});
}

/// Create initial shgit directory structure
pub fn initShgitStructure(allocator: std.mem.Allocator, path: []const u8) !void {
    // Create .shgit/
    const shgit_dir = try std.fs.path.join(allocator, &.{ path, SHGIT_DIR });
    defer allocator.free(shgit_dir);
    try std.fs.cwd().makePath(shgit_dir);

    // Create link/
    const link_dir = try std.fs.path.join(allocator, &.{ path, LINK_DIR });
    defer allocator.free(link_dir);
    try std.fs.cwd().makePath(link_dir);

    // Create repo/
    const repo_dir = try std.fs.path.join(allocator, &.{ path, REPO_DIR });
    defer allocator.free(repo_dir);
    try std.fs.cwd().makePath(repo_dir);

    log.info("created shgit structure at {s}", .{path});
}

test "parseConfig basic" {
    const content =
        \\.{
        \\    .sync_patterns = .{
        \\        ".env",
        \\        ".env.local",
        \\    },
        \\    .main_repo = "myrepo",
        \\}
    ;

    var cfg = try parseConfig(std.testing.allocator, content);
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), cfg.sync_patterns.len);
    try std.testing.expectEqualStrings(".env", cfg.sync_patterns[0]);
    try std.testing.expectEqualStrings(".env.local", cfg.sync_patterns[1]);
    try std.testing.expectEqualStrings("myrepo", cfg.main_repo.?);
}

test "parseConfig empty" {
    const content = ".{\n}\n";
    var cfg = try parseConfig(std.testing.allocator, content);
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), cfg.sync_patterns.len);
    try std.testing.expect(cfg.main_repo == null);
}

const std = @import("std");
const config = @import("../config.zig");
const git = @import("../git.zig");

const log = std.log.scoped(.init);

pub fn execute(io: std.Io, allocator: std.mem.Allocator, verbose: bool) !void {
    _ = verbose;

    // Check if already a shgit project
    if (try config.findShgitRoot(io, allocator)) |root| {
        allocator.free(root);
        log.err("already in a shgit project", .{});
        return error.AlreadyShgitProject;
    }

    var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try std.Io.Dir.cwd().realPath(io, &cwd_buf);
    const cwd = cwd_buf[0..n];

    log.info("initializing shgit in {s}", .{cwd});

    // Initialize git if not already
    const git_dir = try std.fs.path.join(allocator, &.{ cwd, ".git" });
    defer allocator.free(git_dir);

    if (std.Io.Dir.cwd().statFile(io, git_dir, .{})) |_| {
        log.info("git already initialized", .{});
    } else |_| {
        try git.init(io, allocator, cwd);
    }

    // Create shgit structure
    try config.initShgitStructure(io, allocator, cwd);

    // Create default config with .env sync pattern
    const default_patterns = try allocator.alloc(config.SyncPattern, 1);
    default_patterns[0] = .{ .pattern = try allocator.dupe(u8, ".env"), .mode = .symlink };

    var cfg = config.Config{
        .sync_patterns = default_patterns,
    };
    defer cfg.deinit(allocator);

    try config.saveConfig(io, allocator, cwd, cfg);

    // Create .gitignore if not exists
    const gitignore_path = try std.fs.path.join(allocator, &.{ cwd, ".gitignore" });
    defer allocator.free(gitignore_path);

    const file = std.Io.Dir.cwd().createFile(io, gitignore_path, .{ .exclusive = true }) catch |err| {
        if (err == error.PathAlreadyExists) {
            log.info(".gitignore already exists", .{});
            return;
        }
        return err;
    };
    defer file.close(io);

    try file.writeStreamingAll(io,
        \\# Ignore build artifacts in submodules
        \\repo/**/node_modules/
        \\repo/**/target/
        \\repo/**/zig-out/
        \\repo/**/zig-cache/
        \\
    );

    log.info("shgit initialized", .{});
}

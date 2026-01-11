const std = @import("std");
const config = @import("../config.zig");
const git = @import("../git.zig");

const log = std.log.scoped(.init);

pub fn execute(allocator: std.mem.Allocator, verbose: bool) !void {
    _ = verbose;

    // Check if already a shgit project
    if (try config.findShgitRoot(allocator)) |root| {
        allocator.free(root);
        log.err("already in a shgit project", .{});
        return error.AlreadyShgitProject;
    }

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = try std.fs.cwd().realpath(".", &cwd_buf);

    log.info("initializing shgit in {s}", .{cwd});

    // Initialize git if not already
    const git_dir = try std.fs.path.join(allocator, &.{ cwd, ".git" });
    defer allocator.free(git_dir);

    if (std.fs.cwd().statFile(git_dir)) |_| {
        log.info("git already initialized", .{});
    } else |_| {
        try git.init(allocator, cwd);
    }

    // Create shgit structure
    try config.initShgitStructure(allocator, cwd);

    // Create default config
    const cfg = config.Config{};
    try config.saveConfig(allocator, cwd, cfg);

    // Create .gitignore if not exists
    const gitignore_path = try std.fs.path.join(allocator, &.{ cwd, ".gitignore" });
    defer allocator.free(gitignore_path);

    const file = std.fs.cwd().createFile(gitignore_path, .{ .exclusive = true }) catch |err| {
        if (err == error.PathAlreadyExists) {
            log.info(".gitignore already exists", .{});
            return;
        }
        return err;
    };
    defer file.close();

    try file.writeAll(
        \\# Ignore build artifacts in submodules
        \\repo/**/node_modules/
        \\repo/**/target/
        \\repo/**/zig-out/
        \\repo/**/zig-cache/
        \\
    );

    log.info("shgit initialized", .{});
}

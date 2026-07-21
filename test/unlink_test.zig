const std = @import("std");
const shgit = @import("shgit");
const helpers = @import("helpers.zig");
const tio = helpers.tio;
const dir_exists = helpers.dir_exists;

test "unlink removes symlink" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create source file in link/
    try tmp_dir.dir.createDirPath(tio, "link");
    const src_file = try tmp_dir.dir.createFile(tio, "link/.env", .{});
    try src_file.writeStreamingAll(tio, "TEST=value");
    src_file.close(tio);

    // Create target directory and symlink
    try tmp_dir.dir.createDirPath(tio, "repo/myrepo");
    try tmp_dir.dir.symLink(tio, "../../link/.env", "repo/myrepo/.env", .{});

    // Verify symlink exists
    _ = tmp_dir.dir.statFile(tio, "repo/myrepo/.env", .{}) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };

    // Delete the symlink
    try tmp_dir.dir.deleteFile(tio, "repo/myrepo/.env");

    // Verify it's gone
    const result = tmp_dir.dir.statFile(tio, "repo/myrepo/.env", .{});
    try std.testing.expectError(error.FileNotFound, result);
}

test "unlink handles non-existent file" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(tio, "repo/myrepo");

    // Try to delete non-existent file - should not error
    tmp_dir.dir.deleteFile(tio, "repo/myrepo/.env") catch |err| {
        try std.testing.expectEqual(error.FileNotFound, err);
    };
}

test "unlink removes from exclude file" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create .git/info structure with exclude file
    try tmp_dir.dir.createDirPath(tio, ".git/info");
    const exclude_file = try tmp_dir.dir.createFile(tio, ".git/info/exclude", .{});
    try exclude_file.writeStreamingAll(tio, "# Exclude file\n/.env\n/.env.local\n");
    exclude_file.close(tio);

    // Read original content
    const original = try tmp_dir.dir.readFileAlloc(tio, ".git/info/exclude", allocator, .unlimited);
    defer allocator.free(original);
    try std.testing.expect(std.mem.indexOf(u8, original, "/.env") != null);

    // Simulate removal: read, filter, write
    var new_content: std.ArrayList(u8) = .empty;
    defer new_content.deinit(allocator);

    var lines = std.mem.splitScalar(u8, original, '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, "/.env")) {
            continue; // Skip this line
        }
        try new_content.appendSlice(allocator, line);
        try new_content.append(allocator, '\n');
    }

    // Write back
    const out_file = try tmp_dir.dir.createFile(tio, ".git/info/exclude", .{ .truncate = true });
    try out_file.writeStreamingAll(tio, new_content.items);
    out_file.close(tio);

    // Verify
    const modified = try tmp_dir.dir.readFileAlloc(tio, ".git/info/exclude", allocator, .unlimited);
    defer allocator.free(modified);
    try std.testing.expect(std.mem.indexOf(u8, modified, "/.env\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, modified, "/.env.local") != null);
}

test "unlink handles multiple repos" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create multiple repo directories
    try tmp_dir.dir.createDirPath(tio, "repo/main");
    try tmp_dir.dir.createDirPath(tio, "repo/worktree1");
    try tmp_dir.dir.createDirPath(tio, "repo/worktree2");
    try tmp_dir.dir.createDirPath(tio, "link");

    // Create source file
    const src_file = try tmp_dir.dir.createFile(tio, "link/.env", .{});
    try src_file.writeStreamingAll(tio, "TEST=value");
    src_file.close(tio);

    // Create symlinks in all repos
    tmp_dir.dir.symLink(tio, "../../link/.env", "repo/main/.env", .{}) catch {};
    tmp_dir.dir.symLink(tio, "../../link/.env", "repo/worktree1/.env", .{}) catch {};
    tmp_dir.dir.symLink(tio, "../../link/.env", "repo/worktree2/.env", .{}) catch {};

    // Delete all symlinks
    tmp_dir.dir.deleteFile(tio, "repo/main/.env") catch {};
    tmp_dir.dir.deleteFile(tio, "repo/worktree1/.env") catch {};
    tmp_dir.dir.deleteFile(tio, "repo/worktree2/.env") catch {};

    // Verify all are gone
    try std.testing.expectError(error.FileNotFound, tmp_dir.dir.statFile(tio, "repo/main/.env", .{}));
    try std.testing.expectError(error.FileNotFound, tmp_dir.dir.statFile(tio, "repo/worktree1/.env", .{}));
    try std.testing.expectError(error.FileNotFound, tmp_dir.dir.statFile(tio, "repo/worktree2/.env", .{}));
}

test "unlink handles nested paths" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create nested structure
    try tmp_dir.dir.createDirPath(tio, "repo/myrepo/packages/api");
    try tmp_dir.dir.createDirPath(tio, "link/packages/api");

    // Create source file
    const src_file = try tmp_dir.dir.createFile(tio, "link/packages/api/.env", .{});
    try src_file.writeStreamingAll(tio, "API_KEY=secret");
    src_file.close(tio);

    // Create symlink
    tmp_dir.dir.symLink(tio, "../../../../link/packages/api/.env", "repo/myrepo/packages/api/.env", .{}) catch {};

    // Delete symlink
    tmp_dir.dir.deleteFile(tio, "repo/myrepo/packages/api/.env") catch {};

    // Verify it's gone
    try std.testing.expectError(error.FileNotFound, tmp_dir.dir.statFile(tio, "repo/myrepo/packages/api/.env", .{}));
}

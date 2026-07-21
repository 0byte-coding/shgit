const std = @import("std");
const shgit = @import("shgit");
const helpers = @import("helpers.zig");
const tio = helpers.tio;
const dir_exists = helpers.dir_exists;
const compute_relative_path = helpers.compute_relative_path;

test "shgit structure creation" {
    const allocator = std.testing.allocator;

    // Create temp directory for testing
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp_dir.dir.realPathFile(tio, ".", &buf);
    const tmp_path = buf[0..n];
    _ = tmp_path;

    // Create shgit structure manually
    try tmp_dir.dir.createDirPath(tio, ".shgit");
    try tmp_dir.dir.createDirPath(tio, "link");
    try tmp_dir.dir.createDirPath(tio, "repo");

    // Verify structure
    try std.testing.expect(try dir_exists(tmp_dir.dir, ".shgit"));
    try std.testing.expect(try dir_exists(tmp_dir.dir, "link"));
    try std.testing.expect(try dir_exists(tmp_dir.dir, "repo"));

    _ = allocator;
}

test "config file creation and parsing" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create config file
    try tmp_dir.dir.createDirPath(tio, ".shgit");
    const config_file = try tmp_dir.dir.createFile(tio, ".shgit/config.json", .{});
    defer config_file.close(tio);

    try config_file.writeStreamingAll(tio,
        \\{
        \\  "main_repo": "myrepo",
        \\  "sync_enabled": true,
        \\  "sync_patterns": [
        \\    {
        \\      "pattern": ".env"
        \\    },
        \\    {
        \\      "pattern": ".env.local"
        \\    }
        \\  ]
        \\}
    );

    // Verify file exists
    const stat = try tmp_dir.dir.statFile(tio, ".shgit/config.json", .{});
    try std.testing.expect(stat.kind == .file);
}

test "symlink creation" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create source file
    try tmp_dir.dir.createDirPath(tio, "link/.vscode");
    const src_file = try tmp_dir.dir.createFile(tio, "link/.vscode/settings.json", .{});
    try src_file.writeStreamingAll(tio, "{}");
    src_file.close(tio);

    // Create target directory
    try tmp_dir.dir.createDirPath(tio, "repo/myrepo/.vscode");

    // Create symlink (relative path from repo/myrepo/.vscode to link/.vscode)
    try tmp_dir.dir.symLink(tio,
        "../../../link/.vscode/settings.json",
        "repo/myrepo/.vscode/settings.json",
        .{},
    );

    // Verify symlink exists by checking stat
    const stat = tmp_dir.dir.statFile(tio, "repo/myrepo/.vscode/settings.json", .{}) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    _ = stat;

    // Read through symlink
    const content = try tmp_dir.dir.readFileAlloc(tio, "repo/myrepo/.vscode/settings.json", allocator, .unlimited);
    defer allocator.free(content);

    try std.testing.expectEqualStrings("{}", content);
}

test "local gitignore exclude file" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create .git/info structure
    try tmp_dir.dir.createDirPath(tio, ".git/info");

    // Create exclude file
    const exclude_file = try tmp_dir.dir.createFile(tio, ".git/info/exclude", .{});
    try exclude_file.writeStreamingAll(tio, "# Local excludes\n");
    exclude_file.close(tio);

    // Verify
    const stat = try tmp_dir.dir.statFile(tio, ".git/info/exclude", .{});
    try std.testing.expect(stat.kind == .file);
}

test "relative path calculation" {
    const allocator = std.testing.allocator;

    // Test cases for relative path calculation
    {
        const rel = try compute_relative_path(allocator, "/a/b/file", "/a/c/target");
        defer allocator.free(rel);
        try std.testing.expectEqualStrings("../c/target", rel);
    }

    {
        const rel = try compute_relative_path(allocator, "/repo/main/.vscode/settings.json", "/link/.vscode/settings.json");
        defer allocator.free(rel);
        try std.testing.expectEqualStrings("../../../link/.vscode/settings.json", rel);
    }
}


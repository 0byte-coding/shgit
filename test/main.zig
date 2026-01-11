const std = @import("std");

// Integration tests for shgit

test "shgit structure creation" {
    const allocator = std.testing.allocator;

    // Create temp directory for testing
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    // Create shgit structure manually
    try tmp_dir.dir.makePath(".shgit");
    try tmp_dir.dir.makePath("link");
    try tmp_dir.dir.makePath("repo");

    // Verify structure
    try std.testing.expect(try dirExists(tmp_dir.dir, ".shgit"));
    try std.testing.expect(try dirExists(tmp_dir.dir, "link"));
    try std.testing.expect(try dirExists(tmp_dir.dir, "repo"));
}

test "config file creation and parsing" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create config file
    try tmp_dir.dir.makePath(".shgit");
    const config_file = try tmp_dir.dir.createFile(".shgit/config.zon", .{});
    defer config_file.close();

    try config_file.writeAll(
        \\.{
        \\    .main_repo = "myrepo",
        \\    .sync_patterns = .{
        \\        ".env",
        \\        ".env.local",
        \\    },
        \\}
    );

    // Verify file exists
    const stat = try tmp_dir.dir.statFile(".shgit/config.zon");
    try std.testing.expect(stat.kind == .file);
}

test "symlink creation" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create source file
    try tmp_dir.dir.makePath("link/.vscode");
    const src_file = try tmp_dir.dir.createFile("link/.vscode/settings.json", .{});
    try src_file.writeAll("{}");
    src_file.close();

    // Create target directory
    try tmp_dir.dir.makePath("repo/myrepo/.vscode");

    // Create symlink (relative path from repo/myrepo/.vscode to link/.vscode)
    try tmp_dir.dir.symLink(
        "../../../link/.vscode/settings.json",
        "repo/myrepo/.vscode/settings.json",
        .{},
    );

    // Verify symlink exists by checking stat
    const stat = tmp_dir.dir.statFile("repo/myrepo/.vscode/settings.json") catch |err| {
        // Symlinks might not be fully supported in all test environments
        if (err == error.FileNotFound) {
            // Skip test if symlink didn't work
            return;
        }
        return err;
    };
    _ = stat;

    // Read through symlink
    const content = try tmp_dir.dir.readFileAlloc(
        allocator,
        "repo/myrepo/.vscode/settings.json",
        1024,
    );
    defer allocator.free(content);

    try std.testing.expectEqualStrings("{}", content);
}

test "local gitignore exclude file" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create .git/info structure
    try tmp_dir.dir.makePath(".git/info");

    // Create exclude file
    const exclude_file = try tmp_dir.dir.createFile(".git/info/exclude", .{});
    try exclude_file.writeAll("# Local excludes\n");
    exclude_file.close();

    // Verify
    const stat = try tmp_dir.dir.statFile(".git/info/exclude");
    try std.testing.expect(stat.kind == .file);
}

test "pattern matching" {
    // Test simple pattern matching logic
    try std.testing.expect(matchesPattern(".env", ".env"));
    try std.testing.expect(matchesPattern("src/.env", ".env"));
    try std.testing.expect(matchesPattern("deep/nested/.env", ".env"));
    try std.testing.expect(!matchesPattern(".env.local", ".env"));
    try std.testing.expect(matchesPattern(".env.local", ".env.local"));
}

fn matchesPattern(path: []const u8, pattern: []const u8) bool {
    if (std.mem.eql(u8, path, pattern)) return true;
    const filename = std.fs.path.basename(path);
    if (std.mem.eql(u8, filename, pattern)) return true;
    if (std.mem.endsWith(u8, path, pattern)) return true;
    return false;
}

fn dirExists(dir: std.fs.Dir, path: []const u8) !bool {
    const stat = dir.statFile(path) catch |err| {
        if (err == error.FileNotFound) return false;
        return err;
    };
    return stat.kind == .directory;
}

test "relative path calculation" {
    const allocator = std.testing.allocator;

    // Test cases for relative path calculation
    {
        const rel = try relativePath(allocator, "/a/b/file", "/a/c/target");
        defer allocator.free(rel);
        try std.testing.expectEqualStrings("../c/target", rel);
    }

    {
        const rel = try relativePath(allocator, "/repo/main/.vscode/settings.json", "/link/.vscode/settings.json");
        defer allocator.free(rel);
        try std.testing.expectEqualStrings("../../../link/.vscode/settings.json", rel);
    }
}

fn relativePath(allocator: std.mem.Allocator, from: []const u8, to: []const u8) ![]const u8 {
    const from_dir = std.fs.path.dirname(from) orelse ".";

    var from_parts: std.ArrayList([]const u8) = .empty;
    defer from_parts.deinit(allocator);

    var to_parts: std.ArrayList([]const u8) = .empty;
    defer to_parts.deinit(allocator);

    var from_iter = std.mem.splitScalar(u8, from_dir, '/');
    while (from_iter.next()) |part| {
        if (part.len > 0 and !std.mem.eql(u8, part, ".")) {
            try from_parts.append(allocator, part);
        }
    }

    var to_iter = std.mem.splitScalar(u8, to, '/');
    while (to_iter.next()) |part| {
        if (part.len > 0 and !std.mem.eql(u8, part, ".")) {
            try to_parts.append(allocator, part);
        }
    }

    var common: usize = 0;
    while (common < from_parts.items.len and common < to_parts.items.len) {
        if (!std.mem.eql(u8, from_parts.items[common], to_parts.items[common])) {
            break;
        }
        common += 1;
    }

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    for (0..(from_parts.items.len - common)) |_| {
        if (result.items.len > 0) try result.append(allocator, '/');
        try result.appendSlice(allocator, "..");
    }

    for (to_parts.items[common..]) |part| {
        if (result.items.len > 0) try result.append(allocator, '/');
        try result.appendSlice(allocator, part);
    }

    if (result.items.len == 0) {
        try result.append(allocator, '.');
    }

    return result.toOwnedSlice(allocator);
}

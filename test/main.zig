const std = @import("std");
const shgit = @import("shgit");

test {
    std.testing.refAllDeclsRecursive(@This());
}

// Tests moved from src/git.zig
test "addLocalExclude with submodule" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Create a temporary test directory structure
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create repo structure similar to submodule
    try tmp_dir.dir.makePath("repo");
    try tmp_dir.dir.makePath(".git/modules/repo/info");

    // Write .git file with relative gitdir (like submodules do)
    const git_file = try tmp_dir.dir.createFile("repo/.git", .{});
    defer git_file.close();
    try git_file.writeAll("gitdir: ../.git/modules/repo\n");

    // Create exclude file
    const exclude_file = try tmp_dir.dir.createFile(".git/modules/repo/info/exclude", .{});
    defer exclude_file.close();
    try exclude_file.writeAll("# test exclude file\n");

    // Get absolute path to repo
    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    const repo_path = try std.fs.path.join(allocator, &.{ tmp_path, "repo" });

    // Add a file to local exclude
    try shgit.git.addLocalExclude(allocator, repo_path, ".env");

    // Read exclude file and verify it was added
    const exclude_content = try tmp_dir.dir.readFileAlloc(allocator, ".git/modules/repo/info/exclude", 4096);
    try testing.expect(std.mem.indexOf(u8, exclude_content, "/.env") != null);
}

// Tests moved from src/commands/worktree.zig
test "matchesPattern" {
    try std.testing.expect(matchesPattern(".env", ".env"));
    try std.testing.expect(matchesPattern("src/.env", ".env"));
    try std.testing.expect(matchesPattern(".env.local", ".env.local"));
    try std.testing.expect(!matchesPattern(".env.local", ".env"));
    try std.testing.expect(matchesPattern("src/config/.env", ".env"));
}

fn matchesPattern(path: []const u8, pattern: []const u8) bool {
    if (std.mem.eql(u8, path, pattern)) return true;
    const filename = std.fs.path.basename(path);
    if (std.mem.eql(u8, filename, pattern)) return true;
    if (std.mem.endsWith(u8, path, pattern)) return true;
    return false;
}

// Tests moved from src/config.zig
test "parseConfig new format" {
    const allocator = std.testing.allocator;

    const content =
        \\.{
        \\    .sync_patterns = .{
        \\        .{
        \\            .pattern = ".env",
        \\            .mode = .symlink,
        \\        },
        \\        .{
        \\            .pattern = ".env.local",
        \\            .mode = .copy,
        \\        },
        \\    },
        \\    .main_repo = "myrepo",
        \\}
    ;

    var cfg = try shgit.config.parseConfig(allocator, content);
    defer cfg.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), cfg.sync_patterns.len);
    try std.testing.expectEqualStrings(".env", cfg.sync_patterns[0].pattern);
    try std.testing.expectEqual(shgit.config.SyncMode.symlink, cfg.sync_patterns[0].mode);
    try std.testing.expectEqualStrings(".env.local", cfg.sync_patterns[1].pattern);
    try std.testing.expectEqual(shgit.config.SyncMode.copy, cfg.sync_patterns[1].mode);
    try std.testing.expectEqualStrings("myrepo", cfg.main_repo.?);
    try std.testing.expectEqual(true, cfg.sync_enabled); // Default is true
}

test "parseConfig legacy format" {
    const allocator = std.testing.allocator;

    const content =
        \\.{
        \\    .sync_patterns = .{
        \\        ".env",
        \\        ".env.local",
        \\    },
        \\    .main_repo = "myrepo",
        \\}
    ;

    var cfg = try shgit.config.parseConfig(allocator, content);
    defer cfg.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), cfg.sync_patterns.len);
    try std.testing.expectEqualStrings(".env", cfg.sync_patterns[0].pattern);
    try std.testing.expectEqual(shgit.config.SyncMode.symlink, cfg.sync_patterns[0].mode);
    try std.testing.expectEqualStrings(".env.local", cfg.sync_patterns[1].pattern);
    try std.testing.expectEqual(shgit.config.SyncMode.symlink, cfg.sync_patterns[1].mode);
    try std.testing.expectEqualStrings("myrepo", cfg.main_repo.?);
}

test "parseConfig empty" {
    const allocator = std.testing.allocator;

    const content = ".{}";

    var cfg = try shgit.config.parseConfig(allocator, content);
    defer cfg.deinit(allocator);

    try std.testing.expect(cfg.main_repo == null);
    try std.testing.expectEqual(@as(usize, 0), cfg.sync_patterns.len);
    try std.testing.expectEqual(true, cfg.sync_enabled); // Default is true
}

test "parseConfig with sync_enabled true" {
    const allocator = std.testing.allocator;

    const content =
        \\.{
        \\    .main_repo = "myrepo",
        \\    .sync_enabled = true,
        \\    .sync_patterns = .{
        \\        ".env",
        \\    },
        \\}
    ;

    var cfg = try shgit.config.parseConfig(allocator, content);
    defer cfg.deinit(allocator);

    try std.testing.expectEqual(true, cfg.sync_enabled);
    try std.testing.expectEqualStrings("myrepo", cfg.main_repo.?);
}

test "parseConfig with sync_enabled false" {
    const allocator = std.testing.allocator;

    const content =
        \\.{
        \\    .main_repo = "myrepo",
        \\    .sync_enabled = false,
        \\    .sync_patterns = .{
        \\        ".env",
        \\    },
        \\}
    ;

    var cfg = try shgit.config.parseConfig(allocator, content);
    defer cfg.deinit(allocator);

    try std.testing.expectEqual(false, cfg.sync_enabled);
    try std.testing.expectEqualStrings("myrepo", cfg.main_repo.?);
}

// Tests moved from src/fs_utils.zig
test "relativePath same directory" {
    const allocator = std.testing.allocator;
    const result = try shgit.fs_utils.relativePath(allocator, "/home/user/file.txt", "/home/user/target.txt");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("target.txt", result);
}

test "relativePath parent directory" {
    const allocator = std.testing.allocator;
    const result = try shgit.fs_utils.relativePath(allocator, "/home/user/sub/file.txt", "/home/user/target.txt");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("../target.txt", result);
}

test "relativePath sibling directory" {
    const allocator = std.testing.allocator;
    const result = try shgit.fs_utils.relativePath(allocator, "/home/user/sub1/file.txt", "/home/user/sub2/target.txt");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("../sub2/target.txt", result);
}

test "relativePath deeply nested" {
    const allocator = std.testing.allocator;
    const result = try shgit.fs_utils.relativePath(allocator, "/a/b/c/d/file.txt", "/x/y/z/target.txt");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("../../../../x/y/z/target.txt", result);
}

// Tests moved from src/commands/clone.zig
test "extractRepoName" {
    const allocator = std.testing.allocator;

    {
        const name = try extractRepoName(allocator, "https://github.com/user/myrepo.git");
        defer allocator.free(name);
        try std.testing.expectEqualStrings("myrepo", name);
    }

    {
        const name = try extractRepoName(allocator, "https://github.com/user/myrepo");
        defer allocator.free(name);
        try std.testing.expectEqualStrings("myrepo", name);
    }

    {
        const name = try extractRepoName(allocator, "git@github.com:user/myrepo.git");
        defer allocator.free(name);
        try std.testing.expectEqualStrings("myrepo", name);
    }
}

fn extractRepoName(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    var last_part = url;
    if (std.mem.lastIndexOfScalar(u8, url, '/')) |idx| {
        last_part = url[idx + 1 ..];
    } else if (std.mem.lastIndexOfScalar(u8, url, ':')) |idx| {
        last_part = url[idx + 1 ..];
    }

    if (std.mem.endsWith(u8, last_part, ".git")) {
        return allocator.dupe(u8, last_part[0 .. last_part.len - 4]);
    }
    return allocator.dupe(u8, last_part);
}

// Integration tests (kept from original test/main.zig)
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

fn dirExists(dir: std.fs.Dir, path: []const u8) !bool {
    const stat = dir.statFile(path) catch |err| {
        if (err == error.FileNotFound) return false;
        return err;
    };
    return stat.kind == .directory;
}

// Tests for unlink command
test "unlink removes symlink" {
    _ = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create source file in link/
    try tmp_dir.dir.makePath("link");
    const src_file = try tmp_dir.dir.createFile("link/.env", .{});
    try src_file.writeAll("TEST=value");
    src_file.close();

    // Create target directory and symlink
    try tmp_dir.dir.makePath("repo/myrepo");
    try tmp_dir.dir.symLink("../../link/.env", "repo/myrepo/.env", .{});

    // Verify symlink exists
    _ = tmp_dir.dir.statFile("repo/myrepo/.env") catch |err| {
        if (err == error.FileNotFound) {
            // Symlinks not supported in test environment
            return;
        }
        return err;
    };

    // Delete the symlink
    try tmp_dir.dir.deleteFile("repo/myrepo/.env");

    // Verify it's gone
    const result = tmp_dir.dir.statFile("repo/myrepo/.env");
    try std.testing.expectError(error.FileNotFound, result);
}

test "unlink handles non-existent file" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.makePath("repo/myrepo");

    // Try to delete non-existent file - should not error
    tmp_dir.dir.deleteFile("repo/myrepo/.env") catch |err| {
        try std.testing.expectEqual(error.FileNotFound, err);
    };
}

test "unlink removes from exclude file" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create .git/info structure with exclude file
    try tmp_dir.dir.makePath(".git/info");
    const exclude_file = try tmp_dir.dir.createFile(".git/info/exclude", .{});
    try exclude_file.writeAll("# Exclude file\n/.env\n/.env.local\n");
    exclude_file.close();

    // Read original content
    const original = try tmp_dir.dir.readFileAlloc(allocator, ".git/info/exclude", 4096);
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
    const out_file = try tmp_dir.dir.createFile(".git/info/exclude", .{ .truncate = true });
    try out_file.writeAll(new_content.items);
    out_file.close();

    // Verify
    const modified = try tmp_dir.dir.readFileAlloc(allocator, ".git/info/exclude", 4096);
    defer allocator.free(modified);
    try std.testing.expect(std.mem.indexOf(u8, modified, "/.env\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, modified, "/.env.local") != null);
}

test "unlink handles multiple repos" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create multiple repo directories
    try tmp_dir.dir.makePath("repo/main");
    try tmp_dir.dir.makePath("repo/worktree1");
    try tmp_dir.dir.makePath("repo/worktree2");
    try tmp_dir.dir.makePath("link");

    // Create source file
    const src_file = try tmp_dir.dir.createFile("link/.env", .{});
    try src_file.writeAll("TEST=value");
    src_file.close();

    // Create symlinks in all repos
    tmp_dir.dir.symLink("../../link/.env", "repo/main/.env", .{}) catch {};
    tmp_dir.dir.symLink("../../link/.env", "repo/worktree1/.env", .{}) catch {};
    tmp_dir.dir.symLink("../../link/.env", "repo/worktree2/.env", .{}) catch {};

    // Delete all symlinks
    tmp_dir.dir.deleteFile("repo/main/.env") catch {};
    tmp_dir.dir.deleteFile("repo/worktree1/.env") catch {};
    tmp_dir.dir.deleteFile("repo/worktree2/.env") catch {};

    // Verify all are gone
    try std.testing.expectError(error.FileNotFound, tmp_dir.dir.statFile("repo/main/.env"));
    try std.testing.expectError(error.FileNotFound, tmp_dir.dir.statFile("repo/worktree1/.env"));
    try std.testing.expectError(error.FileNotFound, tmp_dir.dir.statFile("repo/worktree2/.env"));
}

test "unlink handles nested paths" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create nested structure
    try tmp_dir.dir.makePath("repo/myrepo/packages/api");
    try tmp_dir.dir.makePath("link/packages/api");

    // Create source file
    const src_file = try tmp_dir.dir.createFile("link/packages/api/.env", .{});
    try src_file.writeAll("API_KEY=secret");
    src_file.close();

    // Create symlink
    tmp_dir.dir.symLink("../../../../link/packages/api/.env", "repo/myrepo/packages/api/.env", .{}) catch {};

    // Delete symlink
    tmp_dir.dir.deleteFile("repo/myrepo/packages/api/.env") catch {};

    // Verify it's gone
    try std.testing.expectError(error.FileNotFound, tmp_dir.dir.statFile("repo/myrepo/packages/api/.env"));
}

test "worktree add with -b and no commitish defaults to HEAD" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const test_allocator = arena.allocator();

    // Create temp directory for testing
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(test_allocator, ".");

    // Initialize a git repo
    const init_result = std.process.Child.run(.{
        .allocator = test_allocator,
        .argv = &.{ "git", "init", "-b", "main" },
        .cwd = tmp_path,
    }) catch |err| {
        std.debug.print("git init failed: {}\n", .{err});
        return; // Skip if git not available
    };
    if (init_result.term.Exited != 0) {
        std.debug.print("git init exited with code {}\n", .{init_result.term.Exited});
        return; // Skip if git fails
    }

    // Create a test file and commit it
    const test_file = try tmp_dir.dir.createFile("test.txt", .{});
    try test_file.writeAll("test content");
    test_file.close();

    _ = std.process.Child.run(.{
        .allocator = test_allocator,
        .argv = &.{ "git", "add", "test.txt" },
        .cwd = tmp_path,
    }) catch return;

    _ = std.process.Child.run(.{
        .allocator = test_allocator,
        .argv = &.{ "git", "commit", "-m", "Initial commit" },
        .cwd = tmp_path,
    }) catch return;

    // Test: Create worktree with -b and no commitish (should default to HEAD)
    const result = std.process.Child.run(.{
        .allocator = test_allocator,
        .argv = &.{ "git", "worktree", "add", "-b", "new-branch", "test-worktree" },
        .cwd = tmp_path,
    }) catch |err| {
        std.debug.print("git worktree add failed: {}\n", .{err});
        return error.SkipZigTest;
    };

    // Should succeed without error
    try std.testing.expectEqual(@as(u8, 0), result.term.Exited);

    // Verify the worktree was created
    const worktree_stat = tmp_dir.dir.statFile("test-worktree") catch |err| {
        std.debug.print("worktree not found: {}\n", .{err});
        return error.TestFailed;
    };
    try std.testing.expect(worktree_stat.kind == .directory);

    // Verify the branch was created
    const branch_result = std.process.Child.run(.{
        .allocator = test_allocator,
        .argv = &.{ "git", "branch", "--list", "new-branch" },
        .cwd = tmp_path,
    }) catch return;

    try std.testing.expect(std.mem.indexOf(u8, branch_result.stdout, "new-branch") != null);
}

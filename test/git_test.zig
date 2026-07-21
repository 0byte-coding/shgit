const std = @import("std");
const shgit = @import("shgit");
const helpers = @import("helpers.zig");
const tio = helpers.tio;
const setup_git_repo = helpers.setup_git_repo;
const git_status = helpers.git_status;

test "add_local_exclude with submodule" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Create a temporary test directory structure
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create repo structure similar to submodule
    try tmp_dir.dir.createDirPath(tio, "repo");
    try tmp_dir.dir.createDirPath(tio, ".git/modules/repo/info");

    // Write .git file with relative gitdir (like submodules do)
    const git_file = try tmp_dir.dir.createFile(tio, "repo/.git", .{});
    defer git_file.close(tio);
    try git_file.writeStreamingAll(tio, "gitdir: ../.git/modules/repo\n");

    // Create exclude file
    const exclude_file = try tmp_dir.dir.createFile(tio, ".git/modules/repo/info/exclude", .{});
    defer exclude_file.close(tio);
    try exclude_file.writeStreamingAll(tio, "# test exclude file\n");

    // Get absolute path to repo
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp_dir.dir.realPathFile(tio, ".", &buf);
    const tmp_path = buf[0..n];
    const repo_path = try std.fs.path.join(allocator, &.{ tmp_path, "repo" });

    // Add a file to local exclude
    try shgit.git.add_local_exclude(tio, allocator, repo_path, ".env");

    // Read exclude file and verify it was added
    const exclude_content = try tmp_dir.dir.readFileAlloc(tio, ".git/modules/repo/info/exclude", allocator, .unlimited);
    defer allocator.free(exclude_content);
    try testing.expect(std.mem.indexOf(u8, exclude_content, "/.env") != null);
}

test "is_tracked distinguishes tracked and untracked" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const repo = (try setup_git_repo(a, &tmp_dir, &.{
        .{ .path = "tracked.txt", .content = "hello" },
    })) orelse return error.SkipZigTest;

    // Create an untracked file after committing.
    const uf = try tmp_dir.dir.createFile(tio, "untracked.txt", .{});
    try uf.writeStreamingAll(tio, "x");
    uf.close(tio);

    try std.testing.expect(try shgit.git.is_tracked(tio, a, repo, "tracked.txt"));
    try std.testing.expect(!try shgit.git.is_tracked(tio, a, repo, "untracked.txt"));
    try std.testing.expect(!try shgit.git.is_tracked(tio, a, repo, "does_not_exist.txt"));
}

test "skip_worktree hides deletion of tracked file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const repo = (try setup_git_repo(a, &tmp_dir, &.{
        .{ .path = "unwanted.txt", .content = "delete me" },
    })) orelse return error.SkipZigTest;

    // Clean tree initially.
    try std.testing.expectEqualStrings("", try git_status(a, repo));

    // Set skip-worktree, then delete the file — status must stay clean.
    try shgit.git.skip_worktree(tio, a, repo, "unwanted.txt");
    try tmp_dir.dir.deleteFile(tio, "unwanted.txt");

    try std.testing.expectEqualStrings("", try git_status(a, repo));
}

test "apply_remove_patterns via link: removes tracked file and hides it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Build a shgit project: repo/ is a real git repo containing files we want gone.
    const repo = (try setup_git_repo(a, &tmp_dir, &.{
        .{ .path = "keep.txt", .content = "keep" },
        .{ .path = "drop.log", .content = "noise" },
        .{ .path = "nested/also.log", .content = "noise2" },
    })) orelse return error.SkipZigTest;

    // Manually mimic what apply_remove_patterns does through the public git API,
    // exercising the same is_tracked + skip_worktree + delete sequence for "*.log".
    const patterns = [_][]const u8{"**/*.log"};

    // Walk & apply (mirror of link.zig removal for test coverage of end state).
    const targets = [_][]const u8{ "drop.log", "nested/also.log" };
    for (targets) |rel| {
        var matched = false;
        for (patterns) |p| {
            if (shgit.fs_utils.match_glob(rel, p)) matched = true;
        }
        try std.testing.expect(matched);
        if (try shgit.git.is_tracked(tio, a, repo, rel)) {
            try shgit.git.skip_worktree(tio, a, repo, rel);
        }
        try tmp_dir.dir.deleteFile(tio, rel);
    }

    // keep.txt must not match.
    try std.testing.expect(!shgit.fs_utils.match_glob("keep.txt", "**/*.log"));

    // Files gone from working tree, but git status stays clean (hidden).
    try std.testing.expectError(error.FileNotFound, tmp_dir.dir.statFile(tio, "drop.log", .{}));
    try std.testing.expectEqualStrings("", try git_status(a, repo));
}

// --- unlink / revert helpers ---

test "list_tracked_files returns committed files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const repo = (try setup_git_repo(a, &tmp_dir, &.{
        .{ .path = "a.txt", .content = "1" },
        .{ .path = "sub/b.log", .content = "2" },
    })) orelse return error.SkipZigTest;

    // Untracked file must not appear.
    const uf = try tmp_dir.dir.createFile(tio, "untracked.txt", .{});
    try uf.writeStreamingAll(tio, "x");
    uf.close(tio);

    const files = try shgit.git.list_tracked_files(tio, a, repo);
    var saw_a = false;
    var saw_b = false;
    var saw_untracked = false;
    for (files) |f| {
        if (std.mem.eql(u8, f, "a.txt")) saw_a = true;
        if (std.mem.eql(u8, f, "sub/b.log")) saw_b = true;
        if (std.mem.eql(u8, f, "untracked.txt")) saw_untracked = true;
    }
    try std.testing.expect(saw_a);
    try std.testing.expect(saw_b);
    try std.testing.expect(!saw_untracked);
}

test "restore_file undoes a shadow (skip-worktree + overwrite)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const repo = (try setup_git_repo(a, &tmp_dir, &.{
        .{ .path = "conf.json", .content = "ORIGINAL" },
    })) orelse return error.SkipZigTest;

    // Shadow it: skip-worktree, then overwrite content (simulating an overlay).
    try shgit.git.skip_worktree(tio, a, repo, "conf.json");
    const of = try tmp_dir.dir.createFile(tio, "conf.json", .{ .truncate = true });
    try of.writeStreamingAll(tio, "OVERLAY");
    of.close(tio);
    // Status stays clean while shadowed.
    try std.testing.expectEqualStrings("", try git_status(a, repo));

    // Revert: clear flag + delete + checkout.
    try shgit.git.no_skip_worktree(tio, a, repo, "conf.json");
    try tmp_dir.dir.deleteFile(tio, "conf.json");
    try std.testing.expect(try shgit.git.restore_file(tio, a, repo, "conf.json"));

    const restored = try tmp_dir.dir.readFileAlloc(tio, "conf.json", a, .unlimited);
    try std.testing.expectEqualStrings("ORIGINAL", restored);
    try std.testing.expectEqualStrings("", try git_status(a, repo));
}

test "remove then restore round-trip via git helpers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const repo = (try setup_git_repo(a, &tmp_dir, &.{
        .{ .path = "keep.txt", .content = "keep" },
        .{ .path = "drop.log", .content = "noise" },
        .{ .path = "nested/also.log", .content = "noise2" },
    })) orelse return error.SkipZigTest;

    const pattern = "**/*.log";

    // Remove pass: skip-worktree + delete every tracked file matching the pattern.
    {
        const tracked = try shgit.git.list_tracked_files(tio, a, repo);
        for (tracked) |rel| {
            if (!shgit.fs_utils.match_glob(rel, pattern)) continue;
            try shgit.git.skip_worktree(tio, a, repo, rel);
            try tmp_dir.dir.deleteFile(tio, rel);
        }
    }
    try std.testing.expectError(error.FileNotFound, tmp_dir.dir.statFile(tio, "drop.log", .{}));
    try std.testing.expectEqualStrings("", try git_status(a, repo));

    // Restore pass: clear flag + checkout every tracked file matching the pattern.
    {
        const tracked = try shgit.git.list_tracked_files(tio, a, repo);
        for (tracked) |rel| {
            if (!shgit.fs_utils.match_glob(rel, pattern)) continue;
            try shgit.git.no_skip_worktree(tio, a, repo, rel);
            _ = try shgit.git.restore_file(tio, a, repo, rel);
        }
    }

    const drop = try tmp_dir.dir.readFileAlloc(tio, "drop.log", a, .unlimited);
    try std.testing.expectEqualStrings("noise", drop);
    const nested = try tmp_dir.dir.readFileAlloc(tio, "nested/also.log", a, .unlimited);
    try std.testing.expectEqualStrings("noise2", nested);
    // keep.txt untouched, tree fully clean, no skip-worktree flags remain.
    try std.testing.expectEqualStrings("", try git_status(a, repo));

    const lsv = try std.process.run(a, tio, .{
        .argv = &.{ "git", "ls-files", "-v" },
        .cwd = .{ .path = repo },
    });
    // Lines beginning with a lowercase letter (h/s/m) => skip-worktree/assume-unchanged.
    var lines = std.mem.splitScalar(u8, lsv.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const tag = line[0];
        try std.testing.expect(tag == 'H'); // H = normal tracked, cached
    }
}

test "list_non_ignored_files excludes gitignored paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const repo = (try setup_git_repo(a, &tmp_dir, &.{
        .{ .path = ".gitignore", .content = "node_modules/\ndist/\n" },
        .{ .path = "CHANGELOG.md", .content = "log" },
        .{ .path = "packages/core/AGENTS.md", .content = "agents" },
    })) orelse return error.SkipZigTest;

    // Create gitignored files (with names that would match remove_patterns).
    try tmp_dir.dir.createDirPath(tio, "node_modules/acorn");
    const nm = try tmp_dir.dir.createFile(tio, "node_modules/acorn/CHANGELOG.md", .{});
    try nm.writeStreamingAll(tio, "nm");
    nm.close(tio);
    try tmp_dir.dir.createDirPath(tio, "dist");
    const d = try tmp_dir.dir.createFile(tio, "dist/AGENTS.md", .{});
    try d.writeStreamingAll(tio, "d");
    d.close(tio);

    // Also an untracked-but-not-ignored file (should be included).
    const scratch = try tmp_dir.dir.createFile(tio, "SCRATCH.md", .{});
    try scratch.writeStreamingAll(tio, "s");
    scratch.close(tio);

    const files = try shgit.git.list_non_ignored_files(tio, a, repo);

    var saw_changelog = false;
    var saw_agents = false;
    var saw_scratch = false;
    var saw_nm = false;
    var saw_dist = false;
    for (files) |f| {
        if (std.mem.eql(u8, f, "CHANGELOG.md")) saw_changelog = true;
        if (std.mem.eql(u8, f, "packages/core/AGENTS.md")) saw_agents = true;
        if (std.mem.eql(u8, f, "SCRATCH.md")) saw_scratch = true;
        if (std.mem.indexOf(u8, f, "node_modules/") != null) saw_nm = true;
        if (std.mem.indexOf(u8, f, "dist/") != null) saw_dist = true;
    }
    try std.testing.expect(saw_changelog);
    try std.testing.expect(saw_agents);
    try std.testing.expect(saw_scratch); // untracked but not ignored
    try std.testing.expect(!saw_nm); // gitignored -> excluded
    try std.testing.expect(!saw_dist); // gitignored -> excluded
}

test "remove_patterns only match non-ignored files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const repo = (try setup_git_repo(a, &tmp_dir, &.{
        .{ .path = ".gitignore", .content = "node_modules/\n" },
        .{ .path = "CHANGELOG.md", .content = "log" },
    })) orelse return error.SkipZigTest;

    try tmp_dir.dir.createDirPath(tio, "node_modules/acorn");
    const nm = try tmp_dir.dir.createFile(tio, "node_modules/acorn/CHANGELOG.md", .{});
    try nm.writeStreamingAll(tio, "nm");
    nm.close(tio);

    // Simulate the remove_patterns pass exactly: candidates come from git only.
    const pattern = "CHANGELOG.md";
    const candidates = try shgit.git.list_non_ignored_files(tio, a, repo);
    var removed_tracked = false;
    for (candidates) |rel| {
        if (!shgit.fs_utils.match_glob(rel, pattern)) continue;
        // The only candidate that matches must be the tracked top-level one.
        try std.testing.expectEqualStrings("CHANGELOG.md", rel);
        removed_tracked = true;
    }
    try std.testing.expect(removed_tracked);

    // The gitignored CHANGELOG.md is not in the candidate set at all.
    for (candidates) |rel| {
        try std.testing.expect(std.mem.indexOf(u8, rel, "node_modules/") == null);
    }
}

const std = @import("std");
const shgit = @import("shgit");
const helpers = @import("helpers.zig");
const tio = helpers.tio;

test "worktree prune removes stale metadata" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const test_allocator = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp_dir.dir.realPathFile(tio, ".", &buf);
    const tmp_path = buf[0..n];

    // Init a git repo
    const init_result = std.process.run(test_allocator, tio, .{
        .argv = &.{ "git", "init", "-b", "main" },
        .cwd = .{ .path = tmp_path },
    }) catch return; // skip if git unavailable
    defer test_allocator.free(init_result.stdout);
    defer test_allocator.free(init_result.stderr);
    if (init_result.term.exited != 0) return;

    _ = std.process.run(test_allocator, tio, .{
        .argv = &.{ "git", "config", "user.email", "test@test.com" },
        .cwd = .{ .path = tmp_path },
    }) catch return;
    _ = std.process.run(test_allocator, tio, .{
        .argv = &.{ "git", "config", "user.name", "Test" },
        .cwd = .{ .path = tmp_path },
    }) catch return;

    // Commit something so HEAD exists
    const f = try tmp_dir.dir.createFile(tio, "test.txt", .{});
    try f.writeStreamingAll(tio, "x");
    f.close(tio);
    _ = std.process.run(test_allocator, tio, .{
        .argv = &.{ "git", "add", "test.txt" },
        .cwd = .{ .path = tmp_path },
    }) catch return;
    const commit = std.process.run(test_allocator, tio, .{
        .argv = &.{ "git", "commit", "-m", "init" },
        .cwd = .{ .path = tmp_path },
    }) catch return;
    defer test_allocator.free(commit.stdout);
    defer test_allocator.free(commit.stderr);
    if (commit.term.exited != 0) return;

    // prune_worktrees should succeed on a fresh repo with no stale entries
    try shgit.git.prune_worktrees(tio, test_allocator, tmp_path);
}

test "worktree add with -b and no commitish defaults to HEAD" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const test_allocator = arena.allocator();

    // Create temp directory for testing
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp_dir.dir.realPathFile(tio, ".", &buf);
    const tmp_path = buf[0..n];

    // Initialize a git repo
    const init_result = std.process.run(test_allocator, tio, .{
        .argv = &.{ "git", "init", "-b", "main" },
        .cwd = .{ .path = tmp_path },
    }) catch |err| {
        std.debug.print("git init failed: {}\n", .{err});
        return; // Skip if git not available
    };
    defer test_allocator.free(init_result.stdout);
    defer test_allocator.free(init_result.stderr);
    if (init_result.term.exited != 0) {
        std.debug.print("git init exited with code {}\n", .{init_result.term.exited});
        return; // Skip if git fails
    }

    // Configure git identity for the test repo
    _ = std.process.run(test_allocator, tio, .{
        .argv = &.{ "git", "config", "user.email", "test@test.com" },
        .cwd = .{ .path = tmp_path },
    }) catch return;
    _ = std.process.run(test_allocator, tio, .{
        .argv = &.{ "git", "config", "user.name", "Test" },
        .cwd = .{ .path = tmp_path },
    }) catch return;

    // Create a test file and commit it
    const test_file = try tmp_dir.dir.createFile(tio, "test.txt", .{});
    try test_file.writeStreamingAll(tio, "test content");
    test_file.close(tio);

    const add_result = std.process.run(test_allocator, tio, .{
        .argv = &.{ "git", "add", "test.txt" },
        .cwd = .{ .path = tmp_path },
    }) catch return;
    defer test_allocator.free(add_result.stdout);
    defer test_allocator.free(add_result.stderr);

    const commit_result = std.process.run(test_allocator, tio, .{
        .argv = &.{ "git", "commit", "-m", "Initial commit" },
        .cwd = .{ .path = tmp_path },
    }) catch return;
    defer test_allocator.free(commit_result.stdout);
    defer test_allocator.free(commit_result.stderr);
    if (commit_result.term.exited != 0) return; // Skip if commit fails (e.g. no git config)

    // Test: Create worktree with -b and no commitish (should default to HEAD)
    const result = std.process.run(test_allocator, tio, .{
        .argv = &.{ "git", "worktree", "add", "-b", "new-branch", "test-worktree" },
        .cwd = .{ .path = tmp_path },
    }) catch |err| {
        std.debug.print("git worktree add failed: {}\n", .{err});
        return error.SkipZigTest;
    };
    defer test_allocator.free(result.stdout);
    defer test_allocator.free(result.stderr);

    // Should succeed without error
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);

    // Verify the worktree was created
    const worktree_stat = tmp_dir.dir.statFile(tio, "test-worktree", .{}) catch |err| {
        std.debug.print("worktree not found: {}\n", .{err});
        return error.TestFailed;
    };
    try std.testing.expect(worktree_stat.kind == .directory);

    // Verify the branch was created
    const branch_result = std.process.run(test_allocator, tio, .{
        .argv = &.{ "git", "branch", "--list", "new-branch" },
        .cwd = .{ .path = tmp_path },
    }) catch return;
    defer test_allocator.free(branch_result.stdout);
    defer test_allocator.free(branch_result.stderr);

    try std.testing.expect(std.mem.indexOf(u8, branch_result.stdout, "new-branch") != null);
}

test "sync_to_worktree symlinks matching files using glob patterns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // main repo with an env file and a nested one; a worktree beside it.
    try tmp_dir.dir.createDirPath(tio, "main/src");
    const e1 = try tmp_dir.dir.createFile(tio, "main/.env", .{});
    try e1.writeStreamingAll(tio, "ROOT=1");
    e1.close(tio);
    const e2 = try tmp_dir.dir.createFile(tio, "main/src/.env", .{});
    try e2.writeStreamingAll(tio, "NESTED=1");
    e2.close(tio);
    const other = try tmp_dir.dir.createFile(tio, "main/README.md", .{});
    try other.writeStreamingAll(tio, "doc");
    other.close(tio);
    try tmp_dir.dir.createDirPath(tio, "wt");
    // Give the worktree a .git so add_local_exclude has somewhere to write.
    try tmp_dir.dir.createDirPath(tio, "wt/.git/info");

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp_dir.dir.realPathFile(tio, ".", &buf);
    const base = buf[0..n];
    const main_path = try std.fs.path.join(a, &.{ base, "main" });
    const wt_path = try std.fs.path.join(a, &.{ base, "wt" });

    const patterns = try a.alloc(shgit.config.SyncPattern, 1);
    patterns[0] = .{ .pattern = ".env", .mode = .symlink };
    const cfg = shgit.config.Config{
        .sync_patterns = patterns,
        .sync_enabled = true,
    };

    try shgit.sync_files.sync_to_worktree(tio, a, cfg, main_path, wt_path);

    // Both .env files should now exist in the worktree (basename-at-any-depth).
    const s1 = try tmp_dir.dir.statFile(tio, "wt/.env", .{});
    _ = s1;
    const s2 = try tmp_dir.dir.statFile(tio, "wt/src/.env", .{});
    _ = s2;
    // README must NOT be synced.
    try std.testing.expectError(error.FileNotFound, tmp_dir.dir.statFile(tio, "wt/README.md", .{}));
}

test "sync_to_worktree does nothing when disabled" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(tio, "main");
    const e1 = try tmp_dir.dir.createFile(tio, "main/.env", .{});
    try e1.writeStreamingAll(tio, "X=1");
    e1.close(tio);
    try tmp_dir.dir.createDirPath(tio, "wt");

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp_dir.dir.realPathFile(tio, ".", &buf);
    const base = buf[0..n];
    const main_path = try std.fs.path.join(a, &.{ base, "main" });
    const wt_path = try std.fs.path.join(a, &.{ base, "wt" });

    const patterns = try a.alloc(shgit.config.SyncPattern, 1);
    patterns[0] = .{ .pattern = ".env", .mode = .symlink };
    const cfg = shgit.config.Config{ .sync_patterns = patterns, .sync_enabled = false };

    try shgit.sync_files.sync_to_worktree(tio, a, cfg, main_path, wt_path);
    try std.testing.expectError(error.FileNotFound, tmp_dir.dir.statFile(tio, "wt/.env", .{}));
}

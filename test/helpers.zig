const std = @import("std");

pub const tio = std.testing.io;

pub fn dir_exists(dir: std.Io.Dir, path: []const u8) !bool {
    const stat = dir.statFile(tio, path, .{}) catch |err| {
        if (err == error.FileNotFound) return false;
        return err;
    };
    return stat.kind == .directory;
}

pub fn compute_relative_path(allocator: std.mem.Allocator, from: []const u8, to: []const u8) ![]const u8 {
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

pub fn setup_git_repo(
    arena: std.mem.Allocator,
    tmp_dir: *std.testing.TmpDir,
    files: []const struct { path: []const u8, content: []const u8 },
) !?[]const u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp_dir.dir.realPathFile(tio, ".", &buf);
    const tmp_path = try arena.dupe(u8, buf[0..n]);

    const init_result = std.process.run(arena, tio, .{
        .argv = &.{ "git", "init", "-b", "main" },
        .cwd = .{ .path = tmp_path },
    }) catch return null;
    if (init_result.term.exited != 0) return null;

    _ = std.process.run(arena, tio, .{
        .argv = &.{ "git", "config", "user.email", "test@test.com" },
        .cwd = .{ .path = tmp_path },
    }) catch return null;
    _ = std.process.run(arena, tio, .{
        .argv = &.{ "git", "config", "user.name", "Test" },
        .cwd = .{ .path = tmp_path },
    }) catch return null;

    for (files) |file| {
        if (std.fs.path.dirname(file.path)) |parent| {
            tmp_dir.dir.createDirPath(tio, parent) catch {};
        }
        const f = try tmp_dir.dir.createFile(tio, file.path, .{});
        try f.writeStreamingAll(tio, file.content);
        f.close(tio);
    }

    _ = std.process.run(arena, tio, .{
        .argv = &.{ "git", "add", "-A" },
        .cwd = .{ .path = tmp_path },
    }) catch return null;
    const commit = std.process.run(arena, tio, .{
        .argv = &.{ "git", "commit", "-m", "init" },
        .cwd = .{ .path = tmp_path },
    }) catch return null;
    if (commit.term.exited != 0) return null;

    return tmp_path;
}

pub fn git_status(arena: std.mem.Allocator, repo_path: []const u8) ![]const u8 {
    const res = try std.process.run(arena, tio, .{
        .argv = &.{ "git", "status", "--porcelain" },
        .cwd = .{ .path = repo_path },
    });
    return std.mem.trim(u8, res.stdout, " \n\r\t");
}

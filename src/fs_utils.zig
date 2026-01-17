const std = @import("std");

const log = std.log.scoped(.fs_utils);

/// Calculate relative path from `from` to `to`
/// E.g., relativePath("/a/b/c/file", "/a/x/y/target") returns "../../x/y/target"
pub fn relativePath(allocator: std.mem.Allocator, from: []const u8, to: []const u8) ![]const u8 {
    // Get directory of 'from' (we want path relative to the directory, not the file)
    const from_dir = std.fs.path.dirname(from) orelse ".";

    // Split paths into components
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

    // Find common prefix length
    var common: usize = 0;
    while (common < from_parts.items.len and common < to_parts.items.len) {
        if (!std.mem.eql(u8, from_parts.items[common], to_parts.items[common])) {
            break;
        }
        common += 1;
    }

    // Build relative path
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    // Add ".." for each remaining component in from_dir
    for (0..(from_parts.items.len - common)) |_| {
        if (result.items.len > 0) try result.append(allocator, '/');
        try result.appendSlice(allocator, "..");
    }

    // Add remaining components from 'to'
    for (to_parts.items[common..]) |part| {
        if (result.items.len > 0) try result.append(allocator, '/');
        try result.appendSlice(allocator, part);
    }

    if (result.items.len == 0) {
        try result.append(allocator, '.');
    }

    return result.toOwnedSlice(allocator);
}

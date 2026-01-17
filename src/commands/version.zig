const std = @import("std");
const build_options = @import("build_options");

const log = std.log.scoped(.version);

pub fn execute(allocator: std.mem.Allocator, verbose: bool) !void {
    _ = allocator;
    _ = verbose;

    // Get version from build.zig.zon
    const version = try std.SemanticVersion.parse(build_options.version);

    var stdout_buf: [10 * build_options.version.len]u8 = undefined;
    var stdout_buffered = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_buffered.interface;

    try stdout.print("shgit v{}.{}.{}", .{ version.major, version.minor, version.patch });
    if (version.pre) |pre| {
        try stdout.print("-{s}", .{pre});
    }
    if (version.build) |build| {
        try stdout.print("+{s}", .{build});
    }
    try stdout.print("\n", .{});
    try stdout.flush();
}

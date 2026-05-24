const std = @import("std");
const build_options = @import("build_options");

const log = std.log.scoped(.version);

pub fn execute(io: std.Io, allocator: std.mem.Allocator, verbose: bool) !void {
    _ = allocator;
    _ = verbose;

    // Get version from build.zig.zon
    const ver = try std.SemanticVersion.parse(build_options.version);

    var buf: [10 * build_options.version.len]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    const stdout = &w.interface;

    try stdout.print("shgit v{}.{}.{}", .{ ver.major, ver.minor, ver.patch });
    if (ver.pre) |pre| {
        try stdout.print("-{s}", .{pre});
    }
    if (ver.build) |build| {
        try stdout.print("+{s}", .{build});
    }
    try stdout.print("\n", .{});
    try stdout.flush();
}

const std = @import("std");
const shgit = @import("shgit");

test "extract_repo_name" {
    const allocator = std.testing.allocator;

    {
        const name = try extract_repo_name(allocator, "https://github.com/user/myrepo.git");
        defer allocator.free(name);
        try std.testing.expectEqualStrings("myrepo", name);
    }

    {
        const name = try extract_repo_name(allocator, "https://github.com/user/myrepo");
        defer allocator.free(name);
        try std.testing.expectEqualStrings("myrepo", name);
    }

    {
        const name = try extract_repo_name(allocator, "git@github.com:user/myrepo.git");
        defer allocator.free(name);
        try std.testing.expectEqualStrings("myrepo", name);
    }
}

fn extract_repo_name(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
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

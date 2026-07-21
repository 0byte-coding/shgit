const std = @import("std");
const shgit = @import("shgit");

test "match_glob basename at any depth" {
    const m = shgit.fs_utils.match_glob;
    try std.testing.expect(m(".env", ".env"));
    try std.testing.expect(m("src/.env", ".env"));
    try std.testing.expect(m("src/config/.env", ".env"));
    try std.testing.expect(m(".env.local", ".env.local"));
    try std.testing.expect(!m(".env.local", ".env"));
}

test "match_glob exact path" {
    const m = shgit.fs_utils.match_glob;
    try std.testing.expect(m("src/some_folder/weird_file.sh", "src/some_folder/weird_file.sh"));
    try std.testing.expect(!m("src/other/weird_file.sh", "src/some_folder/weird_file.sh"));
}

test "match_glob single star does not cross slash" {
    const m = shgit.fs_utils.match_glob;
    try std.testing.expect(m("foo.env", "*.env"));
    try std.testing.expect(m("a/foo.env", "*.env")); // basename fallback (no slash in pattern)
    try std.testing.expect(!m("foo.txt", "*.env"));
    try std.testing.expect(m("src/a.js", "src/*.js"));
    try std.testing.expect(!m("src/sub/a.js", "src/*.js"));
}

test "match_glob globstar crosses directories" {
    const m = shgit.fs_utils.match_glob;
    try std.testing.expect(m("src/sub/a.js", "src/**/*.js"));
    try std.testing.expect(m("src/a.js", "src/**/*.js")); // ** matches zero dirs
    try std.testing.expect(m("a/b/c/d.ts", "**/*.ts"));
    try std.testing.expect(m("d.ts", "**/*.ts"));
}

test "match_glob anchored, wildcards and classes" {
    const m = shgit.fs_utils.match_glob;
    try std.testing.expect(m(".env", "/.env"));
    try std.testing.expect(!m("src/.env", "/.env"));
    try std.testing.expect(m("a.env", "?.env"));
    try std.testing.expect(!m("ab.env", "?.env"));
    try std.testing.expect(m("a.log", "[abc].log"));
    try std.testing.expect(!m("d.log", "[abc].log"));
    try std.testing.expect(m("a.log", "[a-c].log"));
    try std.testing.expect(m("z.log", "[!a-c].log"));
}

test "match_glob directory patterns" {
    const m = shgit.fs_utils.match_glob;
    try std.testing.expect(m("build", "build/"));
    try std.testing.expect(m("build/out.o", "build/"));
    try std.testing.expect(m("src/build/x", "build/"));
    try std.testing.expect(!m("mybuild", "build/"));
    try std.testing.expect(m("node_modules/x/y", "node_modules/"));
}

test "relative_path same directory" {
    const allocator = std.testing.allocator;
    const result = try shgit.fs_utils.relative_path(allocator, "/home/user/file.txt", "/home/user/target.txt");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("target.txt", result);
}

test "relative_path parent directory" {
    const allocator = std.testing.allocator;
    const result = try shgit.fs_utils.relative_path(allocator, "/home/user/sub/file.txt", "/home/user/target.txt");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("../target.txt", result);
}

test "relative_path sibling directory" {
    const allocator = std.testing.allocator;
    const result = try shgit.fs_utils.relative_path(allocator, "/home/user/sub1/file.txt", "/home/user/sub2/target.txt");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("../sub2/target.txt", result);
}

test "relative_path deeply nested" {
    const allocator = std.testing.allocator;
    const result = try shgit.fs_utils.relative_path(allocator, "/a/b/c/d/file.txt", "/x/y/z/target.txt");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("../../../../x/y/z/target.txt", result);
}

const std = @import("std");
const config = @import("../config.zig");
const git = @import("../git.zig");
const fs_utils = @import("../fs_utils.zig");

const log = std.log.scoped(.clone);

pub const CloneArgs = struct {
    url: []const u8,
    name: ?[]const u8 = null,
};

pub fn execute(allocator: std.mem.Allocator, args: anytype, verbose: bool) !void {
    const url = args.positionals.URL;
    const custom_name = args.options.name;

    if (verbose) {
        log.debug("cloning {s}", .{url});
    }

    // Extract repo name from URL
    const repo_name = custom_name orelse extractRepoName(url) orelse {
        log.err("could not extract repo name from URL, use --name", .{});
        return error.InvalidUrl;
    };

    // Create shgit folder name
    const shgit_folder = try std.fmt.allocPrint(allocator, "{s}_shgit", .{repo_name});
    defer allocator.free(shgit_folder);

    log.info("creating {s}/", .{shgit_folder});

    // Check if folder exists
    if (std.fs.cwd().statFile(shgit_folder)) |_| {
        log.err("folder {s} already exists", .{shgit_folder});
        return error.FolderExists;
    } else |_| {}

    // Create folder structure
    try std.fs.cwd().makePath(shgit_folder);

    // Initialize git repo
    try git.init(allocator, shgit_folder);

    // Create structure
    try config.initShgitStructure(allocator, shgit_folder);

    // Add submodule
    const repo_path = try std.fs.path.join(allocator, &.{ config.REPO_DIR, repo_name });
    defer allocator.free(repo_path);

    try git.addSubmodule(allocator, shgit_folder, url, repo_path);

    // Create .gitignore for the shgit folder
    const gitignore_path = try std.fs.path.join(allocator, &.{ shgit_folder, ".gitignore" });
    defer allocator.free(gitignore_path);

    const gitignore_file = try std.fs.cwd().createFile(gitignore_path, .{});
    defer gitignore_file.close();
    try gitignore_file.writeAll(
        \\# Ignore build artifacts in submodules
        \\repo/**/node_modules/
        \\repo/**/target/
        \\repo/**/zig-out/
        \\repo/**/zig-cache/
        \\
    );

    // Create default config
    const cfg = config.Config{
        .sync_patterns = &.{},
        .main_repo = repo_name,
    };
    try config.saveConfig(allocator, shgit_folder, cfg);

    log.info("shgit project created at {s}/", .{shgit_folder});
    log.info("next: cd {s} && shgit link", .{shgit_folder});
}

fn extractRepoName(url: []const u8) ?[]const u8 {
    // Handle URLs like:
    // https://github.com/user/repo.git
    // git@github.com:user/repo.git
    // /path/to/repo

    var name = url;

    // Remove trailing .git
    if (std.mem.endsWith(u8, name, ".git")) {
        name = name[0 .. name.len - 4];
    }

    // Remove trailing slash
    if (std.mem.endsWith(u8, name, "/")) {
        name = name[0 .. name.len - 1];
    }

    // Find last path component
    if (std.mem.lastIndexOfScalar(u8, name, '/')) |idx| {
        return name[idx + 1 ..];
    }

    if (std.mem.lastIndexOfScalar(u8, name, ':')) |idx| {
        return name[idx + 1 ..];
    }

    if (name.len > 0) return name;
    return null;
}

test "extractRepoName" {
    try std.testing.expectEqualStrings("repo", extractRepoName("https://github.com/user/repo.git").?);
    try std.testing.expectEqualStrings("repo", extractRepoName("https://github.com/user/repo").?);
    try std.testing.expectEqualStrings("repo", extractRepoName("git@github.com:user/repo.git").?);
    try std.testing.expectEqualStrings("myrepo", extractRepoName("/path/to/myrepo").?);
}

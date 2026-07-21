const std = @import("std");
const shgit = @import("shgit");

test "parse_config JSON format" {
    const allocator = std.testing.allocator;

    const content =
        \\{
        \\  "sync_patterns": [
        \\    {
        \\      "pattern": ".env",
        \\      "mode": "symlink"
        \\    },
        \\    {
        \\      "pattern": ".env.local",
        \\      "mode": "copy"
        \\    }
        \\  ],
        \\  "main_repo": "myrepo",
        \\  "sync_enabled": true
        \\}
    ;

    var cfg = try shgit.config.parse_config(allocator, content);
    defer cfg.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), cfg.sync_patterns.len);
    try std.testing.expectEqualStrings(".env", cfg.sync_patterns[0].pattern);
    try std.testing.expectEqual(shgit.config.SyncMode.symlink, cfg.sync_patterns[0].mode);
    try std.testing.expectEqualStrings(".env.local", cfg.sync_patterns[1].pattern);
    try std.testing.expectEqual(shgit.config.SyncMode.copy, cfg.sync_patterns[1].mode);
    try std.testing.expectEqualStrings("myrepo", cfg.main_repo.?);
    try std.testing.expectEqual(true, cfg.sync_enabled);
}

test "parse_config with defaults" {
    const allocator = std.testing.allocator;

    const content =
        \\{
        \\  "sync_patterns": [
        \\    {
        \\      "pattern": ".env"
        \\    },
        \\    {
        \\      "pattern": ".env.local"
        \\    }
        \\  ],
        \\  "main_repo": "myrepo"
        \\}
    ;

    var cfg = try shgit.config.parse_config(allocator, content);
    defer cfg.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), cfg.sync_patterns.len);
    try std.testing.expectEqualStrings(".env", cfg.sync_patterns[0].pattern);
    try std.testing.expectEqual(shgit.config.SyncMode.symlink, cfg.sync_patterns[0].mode);
    try std.testing.expectEqualStrings(".env.local", cfg.sync_patterns[1].pattern);
    try std.testing.expectEqual(shgit.config.SyncMode.symlink, cfg.sync_patterns[1].mode);
    try std.testing.expectEqualStrings("myrepo", cfg.main_repo.?);
    try std.testing.expectEqual(true, cfg.sync_enabled); // Default is true
}

test "parse_config empty" {
    const allocator = std.testing.allocator;

    const content = "{}";

    var cfg = try shgit.config.parse_config(allocator, content);
    defer cfg.deinit(allocator);

    try std.testing.expect(cfg.main_repo == null);
    try std.testing.expectEqual(@as(usize, 0), cfg.sync_patterns.len);
    try std.testing.expectEqual(true, cfg.sync_enabled); // Default is true
}

test "parse_config with sync_enabled true" {
    const allocator = std.testing.allocator;

    const content =
        \\{
        \\  "main_repo": "myrepo",
        \\  "sync_enabled": true,
        \\  "sync_patterns": [
        \\    {
        \\      "pattern": ".env"
        \\    }
        \\  ]
        \\}
    ;

    var cfg = try shgit.config.parse_config(allocator, content);
    defer cfg.deinit(allocator);

    try std.testing.expectEqual(true, cfg.sync_enabled);
    try std.testing.expectEqualStrings("myrepo", cfg.main_repo.?);
}

test "parse_config with sync_enabled false" {
    const allocator = std.testing.allocator;

    const content =
        \\{
        \\  "main_repo": "myrepo",
        \\  "sync_enabled": false,
        \\  "sync_patterns": [
        \\    {
        \\      "pattern": ".env"
        \\    }
        \\  ]
        \\}
    ;

    var cfg = try shgit.config.parse_config(allocator, content);
    defer cfg.deinit(allocator);

    try std.testing.expectEqual(false, cfg.sync_enabled);
    try std.testing.expectEqualStrings("myrepo", cfg.main_repo.?);
}

test "parse_config with remove_patterns" {
    const allocator = std.testing.allocator;

    const content =
        \\{
        \\  "main_repo": "myrepo",
        \\  "remove_patterns": [
        \\    ".vscode/",
        \\    "**/*.log",
        \\    "docs/legacy.md"
        \\  ]
        \\}
    ;

    var cfg = try shgit.config.parse_config(allocator, content);
    defer cfg.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), cfg.remove_patterns.len);
    try std.testing.expectEqualStrings(".vscode/", cfg.remove_patterns[0]);
    try std.testing.expectEqualStrings("**/*.log", cfg.remove_patterns[1]);
    try std.testing.expectEqualStrings("docs/legacy.md", cfg.remove_patterns[2]);
    // sync_patterns should default empty and coexist
    try std.testing.expectEqual(@as(usize, 0), cfg.sync_patterns.len);
}

test "parse_config remove_patterns defaults empty" {
    const allocator = std.testing.allocator;
    const content = "{}";
    var cfg = try shgit.config.parse_config(allocator, content);
    defer cfg.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), cfg.remove_patterns.len);
}

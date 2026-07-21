const std = @import("std");

comptime {
    _ = @import("git_test.zig");
    _ = @import("config_test.zig");
    _ = @import("fs_utils_test.zig");
    _ = @import("clone_test.zig");
    _ = @import("integration_test.zig");
    _ = @import("unlink_test.zig");
    _ = @import("worktree_test.zig");
}

test {
    std.testing.refAllDecls(@This());
}

// Root module for shgit - exports all public modules for testing

pub const config = @import("config.zig");
pub const git = @import("git.zig");
pub const fs_utils = @import("fs_utils.zig");
pub const sync_files = @import("sync_files.zig");

// Commands
pub const commands = struct {
    pub const clone = @import("commands/clone.zig");
    pub const link = @import("commands/link.zig");
    pub const worktree = @import("commands/worktree.zig");
    pub const init = @import("commands/init.zig");
};

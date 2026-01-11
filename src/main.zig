const std = @import("std");
const argzon = @import("argzon");

const config = @import("config.zig");
const clone = @import("commands/clone.zig");
const link = @import("commands/link.zig");
const worktree = @import("commands/worktree.zig");
const sync = @import("commands/sync.zig");
const init_cmd = @import("commands/init.zig");

const log = std.log.scoped(.shgit);

const CLI = @import("args.zon");
pub const Args = argzon.Args(CLI, .{});

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    const gpa = gpa_state.allocator();
    defer _ = gpa_state.deinit();

    var stderr_buf: [argzon.MAX_BUF_SIZE]u8 = undefined;
    var stderr_buffered = std.fs.File.stderr().writer(&stderr_buf);
    const stderr = &stderr_buffered.interface;

    var arg_iter = try std.process.argsWithAllocator(gpa);
    defer arg_iter.deinit();

    var args: Args = Args.parse(gpa, &arg_iter, stderr, .{}) catch |err| {
        if (err == error.HelpShown) return;
        return err;
    };
    defer args.free(gpa);

    const verbose = args.flags.verbose;
    if (verbose) {
        log.debug("verbose mode enabled", .{});
    }

    if (args.subcommands_opt) |sub| {
        switch (sub) {
            .clone => |clone_args| try clone.execute(gpa, clone_args, verbose),
            .link => |link_args| try link.execute(gpa, link_args, verbose),
            .worktree => |wt_args| try worktree.execute(gpa, wt_args, verbose),
            .sync => try sync.execute(gpa, verbose),
            .init => try init_cmd.execute(gpa, verbose),
        }
    } else {
        var stdout_buf: [argzon.MAX_BUF_SIZE]u8 = undefined;
        var stdout_buffered = std.fs.File.stdout().writer(&stdout_buf);
        const stdout = &stdout_buffered.interface;
        try Args.writeUsage(stdout);
        try stdout.flush();
    }
}

test {
    std.testing.refAllDecls(@This());
}

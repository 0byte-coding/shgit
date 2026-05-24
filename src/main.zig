const std = @import("std");
const clap = @import("clap");

const config = @import("config.zig");
const clone = @import("commands/clone.zig");
const link = @import("commands/link.zig");
const unlink = @import("commands/unlink.zig");
const worktree = @import("commands/worktree.zig");
const sync = @import("commands/sync.zig");
const init_cmd = @import("commands/init.zig");
const version = @import("commands/version.zig");

const log = std.log.scoped(.shgit);

fn reportDiagnostic(io: std.Io, diag: *clap.Diagnostic, err: anyerror) void {
    diag.reportToFile(io, std.Io.File.stderr(), err) catch {};
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var iter = try init.minimal.args.iterateAllocator(gpa);
    defer iter.deinit();

    // Skip executable name
    _ = iter.next();

    // Main parameters (global flags + subcommand)
    const SubCommand = enum {
        clone,
        link,
        unlink,
        worktree,
        sync,
        init,
        version,
    };

    const main_parsers = .{
        .command = clap.parsers.enumeration(SubCommand),
    };

    const main_params = comptime clap.parseParamsComptime(
        \\-h, --help     Display this help and exit.
        \\-v, --verbose  Enable verbose output.
        \\<command>
        \\
    );

    var diag = clap.Diagnostic{};
    var main_res = clap.parseEx(clap.Help, &main_params, main_parsers, &iter, .{
        .diagnostic = &diag,
        .allocator = gpa,
        .terminating_positional = 0,
    }) catch |err| {
        reportDiagnostic(io, &diag, err);
        return err;
    };
    defer main_res.deinit();

    if (main_res.args.help != 0) {
        try printHelp(io, std.Io.File.stdout());
        return;
    }

    const verbose = main_res.args.verbose != 0;
    if (verbose) {
        log.debug("verbose mode enabled", .{});
    }

    const command = main_res.positionals[0] orelse {
        try printHelp(io, std.Io.File.stdout());
        return;
    };

    switch (command) {
        .clone => try cloneMain(io, gpa, &iter, verbose),
        .link => try linkMain(io, gpa, &iter, verbose),
        .unlink => try unlinkMain(io, gpa, &iter, verbose),
        .worktree => try worktreeMain(io, gpa, &iter, verbose),
        .sync => try sync.execute(io, gpa, verbose),
        .init => try init_cmd.execute(io, gpa, verbose),
        .version => try version.execute(io, gpa, verbose),
    }
}

fn printHelp(io: std.Io, file: std.Io.File) !void {
    const help_text =
        \\shgit - Git overlay for personal project configs
        \\
        \\Usage: shgit [options] <command> [args...]
        \\
        \\Options:
        \\  -h, --help      Display this help and exit
        \\  -v, --verbose   Enable verbose output
        \\
        \\Commands:
        \\  clone           Clone a repository as submodule into shgit structure
        \\  link            Symlink files from link/ into repo and add to local gitignore
        \\  unlink          Remove symlinked file from all repos/worktrees
        \\  worktree        Manage git worktrees with proper symlinks
        \\  sync            Sync env files from main repo to worktrees based on config
        \\  init            Initialize shgit in an existing directory structure
        \\  version         Show shgit version
        \\
        \\Use 'shgit <command> --help' for more information on a command.
        \\
    ;
    var buf: [4096]u8 = undefined;
    var w = file.writer(io, &buf);
    try w.interface.writeAll(help_text);
    try w.interface.flush();
}

fn cloneMain(io: std.Io, gpa: std.mem.Allocator, iter: *std.process.Args.Iterator, verbose: bool) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help         Display this help and exit.
        \\-n, --name <str>   Custom name for the shgit folder (default: derived from URL).
        \\<str>
        \\
    );

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = gpa,
    }) catch |err| {
        reportDiagnostic(io, &diag, err);
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        const help_text =
            \\Usage: shgit clone [options] <url>
            \\
            \\Clone a repository as submodule into shgit structure.
            \\
            \\Options:
            \\  -h, --help          Display this help and exit
            \\  -n, --name <str>    Custom name for the shgit folder (default: derived from URL)
            \\
            \\Arguments:
            \\  <url>               Git repository URL to clone
            \\
        ;
        var buf: [4096]u8 = undefined;
        var w = std.Io.File.stdout().writer(io, &buf);
        try w.interface.writeAll(help_text);
        try w.interface.flush();
        return;
    }

    const url = res.positionals[0] orelse return error.MissingUrl;
    const clone_args = clone.CloneArgs{
        .url = url,
        .name = res.args.name,
    };
    try clone.execute(io, gpa, clone_args, verbose);
}

fn linkMain(io: std.Io, gpa: std.mem.Allocator, iter: *std.process.Args.Iterator, verbose: bool) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help           Display this help and exit.
        \\-t, --target <str>   Target repo/worktree to link into (default: repo/).
        \\
    );

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = gpa,
    }) catch |err| {
        reportDiagnostic(io, &diag, err);
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        const help_text =
            \\Usage: shgit link [options]
            \\
            \\Symlink files from link/ into repo and add to local gitignore.
            \\
            \\Options:
            \\  -h, --help            Display this help and exit
            \\  -t, --target <str>    Target repo/worktree to link into (default: repo/)
            \\
        ;
        var buf: [4096]u8 = undefined;
        var w = std.Io.File.stdout().writer(io, &buf);
        try w.interface.writeAll(help_text);
        try w.interface.flush();
        return;
    }

    const link_args = link.LinkArgs{
        .target = res.args.target,
    };
    try link.execute(io, gpa, link_args, verbose);
}

fn unlinkMain(io: std.Io, gpa: std.mem.Allocator, iter: *std.process.Args.Iterator, verbose: bool) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help  Display this help and exit.
        \\<str>
        \\
    );

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = gpa,
    }) catch |err| {
        reportDiagnostic(io, &diag, err);
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        const help_text =
            \\Usage: shgit unlink <path>
            \\
            \\Remove symlinked file from all repos/worktrees and local gitignore.
            \\
            \\Options:
            \\  -h, --help  Display this help and exit
            \\
            \\Arguments:
            \\  <path>      Relative path to unlink (e.g., packages/supabase/config.toml)
            \\
        ;
        var buf: [4096]u8 = undefined;
        var w = std.Io.File.stdout().writer(io, &buf);
        try w.interface.writeAll(help_text);
        try w.interface.flush();
        return;
    }

    const path = res.positionals[0] orelse return error.MissingPath;
    const unlink_args = unlink.UnlinkArgs{
        .path = path,
    };
    try unlink.execute(io, gpa, unlink_args, verbose);
}

fn worktreeMain(io: std.Io, gpa: std.mem.Allocator, iter: *std.process.Args.Iterator, verbose: bool) !void {
    const WorktreeSubCommand = enum {
        add,
        remove,
        list,
    };

    const wt_parsers = .{
        .subcommand = clap.parsers.enumeration(WorktreeSubCommand),
    };

    const wt_params = comptime clap.parseParamsComptime(
        \\-h, --help  Display this help and exit.
        \\<subcommand>
        \\
    );

    var diag = clap.Diagnostic{};
    var wt_res = clap.parseEx(clap.Help, &wt_params, wt_parsers, iter, .{
        .diagnostic = &diag,
        .allocator = gpa,
        .terminating_positional = 0,
    }) catch |err| {
        reportDiagnostic(io, &diag, err);
        return err;
    };
    defer wt_res.deinit();

    const worktree_help =
        \\Usage: shgit worktree <subcommand> [args...]
        \\
        \\Manage git worktrees with proper symlinks.
        \\
        \\Options:
        \\  -h, --help  Display this help and exit
        \\
        \\Subcommands:
        \\  add         Create a new worktree with symlinks
        \\  remove      Remove a worktree
        \\  list        List all worktrees
        \\
    ;

    if (wt_res.args.help != 0) {
        var buf: [4096]u8 = undefined;
        var w = std.Io.File.stdout().writer(io, &buf);
        try w.interface.writeAll(worktree_help);
        try w.interface.flush();
        return;
    }

    const subcommand = wt_res.positionals[0] orelse {
        var buf: [4096]u8 = undefined;
        var w = std.Io.File.stdout().writer(io, &buf);
        try w.interface.writeAll(worktree_help);
        try w.interface.flush();
        return;
    };

    switch (subcommand) {
        .add => try worktreeAddMain(io, gpa, iter, verbose),
        .remove => try worktreeRemoveMain(io, gpa, iter, verbose),
        .list => try worktree.executeList(io, gpa, verbose),
    }
}

fn worktreeAddMain(io: std.Io, gpa: std.mem.Allocator, iter: *std.process.Args.Iterator, verbose: bool) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help             Display this help and exit.
        \\-b, --new-branch <str> Create new branch with this name.
        \\<str>...
        \\
    );

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = gpa,
    }) catch |err| {
        reportDiagnostic(io, &diag, err);
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        const help_text =
            \\Usage: shgit worktree add [options] <name> [<commitish>]
            \\
            \\Create a new worktree with symlinks.
            \\
            \\Options:
            \\  -h, --help                 Display this help and exit
            \\  -b, --new-branch <str>     Create new branch with this name
            \\
            \\Arguments:
            \\  <name>                     Name for the worktree
            \\  <commitish>                Branch to checkout, or start point when using -b
            \\                             (optional when using -b; defaults to HEAD)
            \\
        ;
        var buf: [4096]u8 = undefined;
        var w = std.Io.File.stdout().writer(io, &buf);
        try w.interface.writeAll(help_text);
        try w.interface.flush();
        return;
    }

    // When using <str>..., res.positionals is a tuple with [0] being []const []const u8
    if (res.positionals[0].len == 0) return error.MissingName;

    const name = res.positionals[0][0];
    const new_branch = res.args.@"new-branch";

    // When -b is provided, commitish is optional (defaults to HEAD)
    // When -b is not provided, commitish is required
    const commitish = if (res.positionals[0].len > 1)
        res.positionals[0][1]
    else if (new_branch != null)
        "HEAD"
    else
        return error.MissingCommitish;

    const add_args = worktree.WorktreeAddArgs{
        .name = name,
        .commitish = commitish,
        .new_branch = new_branch,
    };
    try worktree.executeAdd(io, gpa, add_args, verbose);
}

fn worktreeRemoveMain(io: std.Io, gpa: std.mem.Allocator, iter: *std.process.Args.Iterator, verbose: bool) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help  Display this help and exit.
        \\<str>
        \\
    );

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = gpa,
    }) catch |err| {
        reportDiagnostic(io, &diag, err);
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        const help_text =
            \\Usage: shgit worktree remove <name>
            \\
            \\Remove a worktree.
            \\
            \\Options:
            \\  -h, --help  Display this help and exit
            \\
            \\Arguments:
            \\  <name>      Name of the worktree to remove
            \\
        ;
        var buf: [4096]u8 = undefined;
        var w = std.Io.File.stdout().writer(io, &buf);
        try w.interface.writeAll(help_text);
        try w.interface.flush();
        return;
    }

    const name = res.positionals[0] orelse return error.MissingName;
    const remove_args = worktree.WorktreeRemoveArgs{
        .name = name,
    };
    try worktree.executeRemove(io, gpa, remove_args, verbose);
}

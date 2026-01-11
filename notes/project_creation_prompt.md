/init Init this project with git main branch. Then run zig init to init the project, dont forget to create a .gitignore file. Write Output with extreme brevity, sacrifice grammar for conciseness. Write a readme that says this is shgit, its an addition to working with git but a bit "shit", thats why the name.
​
The purpose of this project is to make it easy to work on git projects but being able to store own project specific stuff which cannot be committed to the target repository but should still be git versioned on our own private git repository.

The workflow should look like this:

1. Instead of using git clone, the tool will provide shgit clone, what it will do it will create a folder called like the repository and _shgit so like: <reponame>_shgit

2. This folder will look like this:

foorepo_shgit/
  link/ # same file structure for the target files
    .vscode/
      settings.json
    .opencode/
      opencode.json
  repo/
    foorepo_submodulerepo/
    repoworktree1/
    repoworktree2/
    ...
  .gitignore
  .gitsubmodulefile_whateverthenameofitis...

so it should init the folder with git with main branch and use submodules and put the submodule repo into "repo/" folder. Note that I will also want a shgit command to easily create worktrees

The "link/" folder is whats interesting, it will contain files that I want to git track in my personal repo so "foorepo_shgit" which will be committed to my private repo but thats not part of the tool, the tool shouldnt set the remote or anything like that. The user will set the remote and use git normally to commit it.
The "link/" folder contains files which should be git tracked in my own private repo and which cant be tracked on the target repo, for example the opencode.json file, this file should then be relative symlinked into the repo project and like locally git ignored so that it does not cause problems on the target repo when doing commits, merges or branch switching. We dont care about the file that is on the target repo if any at all, just our own file.
So when the user creates his files there should be the "shgit link" command which will symlink the files to the correct places and make sure its locally gitignored for the target repo.
Its important that the "link/" folder has the same file structure as the project so the tools know how to correctly symlink it and to where. Note that the tool should not be responsible for creating those files or the link/ structure, that is what the user will do.
The tool should have a way to create git worktrees and when doing that, it should also symlink that files correctly for that worktree.
Also another feature of the tool is in the foorepo_shgit at the root level I want to store a `.shgit` folder that contains configs, probably just one config but its better to have it in a folder than to spill the file at the root of the project. The additional feature that I want is that when creating git worktrees, .env file secrets and other non tracked files which are important for the project to function are not preserved. I want this tool to be able to relative symlink the env files from the target repo into its git worktree folders. And in the shgit config you can configure on how exactly that works and for what files, I esentially want something similar like what `.gitignore` does with simple pattern matching so I would just say ".env" in it, and it would symlink all .env files it finds and since its simple pattern matching I can be also very specific like `src/some_folder/weird_file.sh` and it will be symlinked correctly in the worktree.

​
​
I want a src/ and a test/ folder, make sure to write tests to make sure the functionality works.  Use scoped logging for the project using zigs std.log.scoped and make use of the levels (err, warn, info, debug)
​
const my_log = std.log.scoped(.my_scope);
​
my_log.info("Hello from my_scope", .{});

Other project requirements:
- Using zig 0.15.2 (already installed and using)
- Besides argzon there shouldnt be any other needed dependencies, dependencies should be kept minimal
- Using argzon for command line argument parsing using ZON.
Can be added to the project like so:
zig fetch --save git+https://codeberg.org/tensorush/argzon.git

and add it in the build.zig:
```zig
const argzon_dep = b.dependency("argzon", .{
    .target = target,
    .optimize = optimize,
});
const argzon_mod = argzon_dep.module("argzon");

const root_mod = b.createModule(.{
    .target = target,
    .optimize = optimize,
    .imports = &.{
        .{ .name = "argzon", .module = argzon_mod },
    },
});
```

You then create an args.zon file in the src/ folder, here is an example:
```zig
.{
    // Command name (required)
    .name = "command",
    // Description (optional)
    .description = "Command description",
    // Note with additional multi-line information (optional)
    .note =
    \\Additional information
    \\...
    ,
    // Named option parameters (optional)
    .options = .{
        .{
            // Short name (optional)
            .short = 'o',
            // Long name (required)
            .long = "option",
            // Non-boolean primitive or user enum (required)
            .type = "Mode",
            // Default value of specified type, if ".type = ?..." then ".default = null" (optional)
            .default = .zon,
            // Description (optional)
            .description = "Enable option",
            // Note with additional multi-line information (optional)
            .note =
            \\Additional information
            \\...
            ,
            // Accumulate non-nullable values into `_: std.ArrayList(<type>) = try .initCapacity(allocator, <capacity>);` (optional)
            .capacity = 2,
            // Generate opposite option as "--no-<long>...<with_no><description_after_first_word_without_parenthesis_blocks>",
            // which either nulls the value or clears accumulated values (optional)
            .with_no = "Disable",
            // Depend on either one of other named parameters,
            // for non-accumulated enum options possibly also providing space-separated values (optional)
            .dependencies = .{
                // "flag",
            },
            // Mutually exclude simultaneous usage of conflicting named parameters,
            // for non-accumulated enum options possibly also providing space-separated values (optional)
            .excludes = .{
                // "flag",
            },
        },
    },
    // Named flag parameters (optional)
    // Same as options but with ".type = bool" and ".default = false",
    // "-h, --help" flag is reserved and handled automatically.
    .flags = .{
        .{
            // Short name (optional)
            .short = 'f',
            // Long name (required)
            .long = "flag",
            // Description (optional)
            .description = "Set flag",
            // Note with additional multi-line information (optional)
            .note =
            \\Additional information
            \\...
            ,
            // Count repetitions with `std.math.IntFittingRange(0, <capacity>)` (optional)
            .capacity = 4,
            // Generate opposite flag as "--no-<long>...<with_no><description_after_first_word_without_parenthesis_blocks>",
            // which either unsets the flag or zeroes repetition count (optional)
            .with_no = "Unset",
            // Depend on either one of other named parameters,
            // for non-accumulated enum options possibly also providing space-separated values (optional)
            .dependencies = .{
                // "option zon",
            },
            // Mutually exclude simultaneous usage of conflicting named parameters,
            // for non-accumulated enum options possibly also providing space-separated values (optional)
            .excludes = .{
                // "option zon",
            },
        },
    },
    // Positional parameters (optional)
    // Accumulated positional values are interrupted by " -- ".
    .positionals = .{
        .{
            // Meta name tag, SCREAMING_SNAKE_CASE (required)
            .meta = .POSITIONAL,
            // Non-optional, non-boolean primitive or non-optional user enum (required)
            .type = "string",
            // Default value of specified type (optional)
            .default = ".",
            // Description (optional)
            .description = "Positional description",
            // Note with additional multi-line information (optional)
            .note =
            \\Additional information
            \\...
            ,
            // Accumulate non-nullable values into `_: std.ArrayList(<type>) = try .initCapacity(allocator, <capacity>);` (optional)
            .capacity = 4,
        },
    },
    // Subcommands (optional)
    .subcommands = .{
        // Same as command.
    },
}
```

And this example shows on how to use argzon:
```sh
//! Basic CLI.

const std = @import("std");

const argzon = @import("argzon");

const CLI = @import("cli.zon");

pub fn main() !void {
    // Set up debug allocator
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    const gpa = gpa_state.allocator();
    defer if (gpa_state.deinit() == .leak) @panic("Memory leaked!");

    // Set up standard output writer
    var stdout_buf: [argzon.MAX_BUF_SIZE]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const writer = &stdout_writer.interface;

    // Set up standard error writer
    var stderr_buf: [argzon.MAX_BUF_SIZE]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);

    // Create arguments according to CLI and user enum definitions
    const Args = argzon.Args(CLI, .{ .enums = &.{std.zig.Ast.Mode} });

    // Write usage
    try writer.print("{s:=^" ++ argzon.FMT_WIDTH ++ "}\n", .{"USAGE"});
    try Args.writeUsage(writer);

    // Write help
    try writer.print("{s:=^" ++ argzon.FMT_WIDTH ++ "}\n", .{"HELP"});
    try Args.writeHelp(writer, .{});

    // Allocate process arguments
    var arg_str_iter = try std.process.argsWithAllocator(gpa);
    defer arg_str_iter.deinit();

    // Parse command-line arguments
    var args: Args = try .parse(gpa, &arg_str_iter, &stderr_writer.interface, .{});
    defer args.free(gpa);

    // Print parsed arguments (all values must be initialized)
    try writer.print("{s:=^" ++ argzon.FMT_WIDTH ++ "}\n{f}", .{ "ARGUMENTS", args.format(null) });

    // Flush standard output
    try writer.flush();
}
```


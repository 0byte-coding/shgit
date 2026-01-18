# AGENTS.md - Coding Agent Guidelines for shgit

## Project Overview
shgit is a Zig CLI tool for managing personal project overlays with git. It allows storing project-specific files (configs, env templates) that can't be committed to the target repo but should be git-versioned in a private repo.

## Build Commands
```bash
zig build                                       # Build the project
zig build -Dcross=true -Doptimize=ReleaseFast   # Compile for target systems
zig build -Doptimize=ReleaseFast                # Build with release optimizations
zig build run -- <args>                         # Run the CLI
zig build test                                  # Run all tests
zig build test -Dtest-filter="pattern"          # Run single test by name filter
```

## Project Structure
```
shgit/
  src/
    main.zig          # Entry point, CLI parsing with zig-clap
    config.zig        # Config loading/saving, shgit structure
    git.zig           # Git command wrappers
    fs_utils.zig      # Filesystem utilities (relative path calc)
    commands/
      clone.zig       # shgit clone command
      link.zig        # shgit link command
      worktree.zig    # shgit worktree add/remove/list
      sync.zig        # shgit sync command
      init.zig        # shgit init command
  test/
    main.zig          # Integration tests
  build.zig           # Build configuration
  build.zig.zon       # Package manifest with dependencies
```

## Code Style Guidelines

### Imports
Order: 1) `std` library 2) External deps (e.g., `clap`) 3) Local modules (relative imports)
```zig
const std = @import("std");
const clap = @import("clap");
const config = @import("../config.zig");
```

### Logging
Use scoped logging for all modules:
```zig
const log = std.log.scoped(.module_name);
log.err("critical error: {}", .{err});
log.warn("warning message", .{});
log.info("informational message", .{});
log.debug("debug details", .{});
```

### Error Handling
- Return errors explicitly, don't panic
- Use `errdefer` for cleanup on error paths
- Log errors with context before returning

```zig
pub fn doSomething() !void {
    const resource = try allocate();
    errdefer resource.deinit();
    doWork() catch |err| {
        log.err("work failed: {}", .{err});
        return err;
    };
}
```

### Memory Management
- Always pass allocator as first parameter
- Use `defer` for cleanup in success path, `errdefer` for error path
- Prefer `.empty` initialization for ArrayLists in Zig 0.15+
```zig
var list: std.ArrayList([]const u8) = .empty;
defer list.deinit(allocator);
try list.append(allocator, item);
```

### Naming Conventions
- Functions: `camelCase`
- Types: `PascalCase`
- Constants: `SCREAMING_SNAKE_CASE` for comptime, `snake_case` for runtime
- Files: `snake_case.zig`
- Scopes for logging: `.snake_case`

### File Writers (Zig 0.15)
```zig
var buf: [4096]u8 = undefined;
var file_writer = file.writer(&buf);
const writer = &file_writer.interface;
try writer.writeAll("content");
try writer.print("{s}\n", .{value});
try writer.flush();
```

### Testing
- **All tests go in the `test/` folder, NOT in source files**
- Tests import the shgit module via `const shgit = @import("shgit")`
- Unit tests for specific modules go in `test/main.zig`
- Integration tests also go in `test/main.zig`
- The `src/root.zig` file exports all modules for testing
- The `test/main.zig` file must include:
  ```zig
  const std = @import("std");
  const shgit = @import("shgit");

  test {
      std.testing.refAllDeclsRecursive(@This());
  }
  ```
- Use `std.testing.allocator` for memory leak detection
- Access modules via `shgit.module_name` (e.g., `shgit.git`, `shgit.config`, `shgit.fs_utils`)

## CLI Argument Parsing (zig-clap)
Arguments are parsed using zig-clap's `parseParamsComptime` in `src/main.zig`:
```zig
const params = comptime clap.parseParamsComptime(
    \\-h, --help         Display this help and exit.
    \\-n, --name <str>   Custom name (optional).
    \\<str>              Required positional argument.
    \\<str>...           Multiple positional arguments.
    \\
);

var diag = clap.Diagnostic{};
var res = clap.parseEx(clap.Help, &params, clap.parsers.default, &iter, .{
    .diagnostic = &diag,
    .allocator = gpa,
}) catch |err| {
    reportDiagnostic(&diag, err);
    return err;
};
defer res.deinit();
```

Access parsed args:
- Flags: `res.args.help` (count, 0 if not set)
- Options: `res.args.name` (optional, `?[]const u8`)
- Positionals: `res.positionals[0]` (tuples indexed from 0)
- Subcommands: Use `terminating_positional` option and enum parsing

## Configuration Files
Config stored in `.shgit/config.zon`:
```zig
.{
    .main_repo = "reponame",
    .sync_patterns = .{ ".env", ".env.local" },
}
```

## Key Patterns

### Command Pattern
Each command defines its argument struct and exports an `execute` function:
```zig
pub const CommandArgs = struct {
    option: ?[]const u8 = null,
    required_arg: []const u8,
};

pub fn execute(allocator: std.mem.Allocator, args: CommandArgs, verbose: bool) !void {
    const shgit_root = try config.findShgitRoot(allocator) orelse {
        log.err("not in a shgit project", .{});
        return error.NotShgitProject;
    };
    defer allocator.free(shgit_root);
}
```

### Git Operations
Use `git.zig` wrapper for git commands:
```zig
try git.init(allocator, path);
try git.addSubmodule(allocator, cwd, url, subpath);
try git.addWorktree(allocator, repo_path, worktree_path, branch);
```

### Symlink Creation
Use relative paths for symlinks and add to local git exclude:
```zig
const rel_link = try fs_utils.relativePath(allocator, target_file, link_file);
defer allocator.free(rel_link);
try std.fs.cwd().symLink(rel_link, target_file, .{});
try git.addLocalExclude(allocator, repo_path, rel_path);
```

## Dependencies
- **zig-clap**: CLI argument parsing
  - Add: `zig fetch --save https://github.com/Hejsil/zig-clap/archive/refs/tags/0.11.0.tar.gz`

## Common Pitfalls
1. ArrayList in Zig 0.15 uses `.empty` init, not `.init(allocator)`
2. File.writer() requires a buffer parameter
3. Use `&writer.interface` to get the actual writer interface
4. For error reporting with clap, use the `reportDiagnostic` helper function
5. Subcommands use `terminating_positional` to parse first positional as enum

## Testing Your Changes
**IMPORTANT**: After making any code changes, always build and run tests to ensure everything still works:
```bash
zig build                  # Verify the project builds
zig build test             # Run all tests to catch regressions
```

# AGENTS.md - Coding Agent Guidelines for shgit

## Project Overview
shgit is a Zig CLI tool for managing personal project overlays with git. It allows storing project-specific files (configs, env templates) that can't be committed to the target repo but should be git-versioned in a private repo.

## Build Commands
```bash
zig build                                    # Build the project
zig build -Doptimize=ReleaseFast            # Build with release optimizations
zig build run -- <args>                      # Run the CLI
zig build test                               # Run all tests
zig build test -Dtest-filter="pattern"       # Run single test by name filter
```

## Project Structure
```
shgit/
  src/
    main.zig          # Entry point, CLI parsing with argzon
    args.zon          # CLI argument definitions (ZON format)
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
Order: 1) `std` library 2) External deps (e.g., `argzon`) 3) Local modules (relative imports)
```zig
const std = @import("std");
const argzon = @import("argzon");
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
- Unit tests go in the same file as the code being tested
- Integration tests go in `test/main.zig`
- Use `std.testing.allocator` for memory leak detection

## CLI Argument Parsing (argzon)
Arguments defined in `src/args.zon` using ZON format:
```zig
.{
    .name = "command",
    .description = "Description",
    .options = .{
        .{ .long = "option", .type = "?string", .description = "Option" },
    },
    .positionals = .{
        .{ .meta = .NAME, .type = "string", .description = "Positional arg" },
    },
    .subcommands = .{ ... },
}
```
Access parsed args:
- Flags: `args.flags.verbose`
- Options: `args.options.name` (optional types are `?T`)
- Positionals: `args.positionals.NAME`
- Subcommands: `args.subcommands_opt` (note: `_opt` suffix)

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
Each command exports an `execute` function:
```zig
pub fn execute(allocator: std.mem.Allocator, args: anytype, verbose: bool) !void {
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
- **argzon**: CLI argument parsing (ZON-based)
  - Add: `zig fetch --save git+https://codeberg.org/tensorush/argzon.git`

## Common Pitfalls
1. ArrayList in Zig 0.15 uses `.empty` init, not `.init(allocator)`
2. File.writer() requires a buffer parameter
3. Use `&writer.interface` to get the actual writer interface
4. Subcommands are accessed via `subcommands_opt`, not `subcommand`
5. Optional option types use `?string` in args.zon

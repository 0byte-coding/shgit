# Coding Agent Guidelines for shgit

## Code Style Guidelines

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
pub fn do_something() !void {
    const resource = try allocate();
    errdefer resource.deinit();
    do_work() catch |err| {
        log.err("work failed: {}", .{err});
        return err;
    };
}
```

### Memory Management

- Always pass allocator as first parameter
- Use `defer` for cleanup in success path, `errdefer` for error path

### Naming Conventions

- Functions: `snake_case`
- Variables: `snake_case`
- Types: `PascalCase`
- Constants: `SCREAMING_SNAKE_CASE` for comptime, `snake_case` for runtime
- Files: `snake_case.zig`
- Scopes for logging: `.snake_case`

### Testing

- **All tests go in the `test/` folder, NOT in source files**
- `test/main.zig` is the entrypoint that imports every other test file; add new test files there
- Group tests by module in dedicated files (e.g., `test/git_test.zig`, `test/config_test.zig`)
- Shared test helpers live in `test/helpers.zig`
- Tests import the shgit module via `const shgit = @import("shgit")`
- The `src/root.zig` file exports all modules for testing
- Use `std.testing.allocator` for memory leak detection
- Access modules via `shgit.module_name` (e.g., `shgit.git`, `shgit.config`, `shgit.fs_utils`)

## Testing Your Changes

**IMPORTANT**: After making any code changes, always build and run tests to ensure everything still works:

```bash
zig build                  # Verify the project builds
zig build test             # Run all tests to catch regressions
```

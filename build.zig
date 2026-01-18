const std = @import("std");

const cross_targets: []const std.Target.Query = &.{
    .{ .cpu_arch = .aarch64, .os_tag = .macos },
    .{ .cpu_arch = .x86_64, .os_tag = .macos },
    .{ .cpu_arch = .aarch64, .os_tag = .linux },
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
    .{ .cpu_arch = .x86_64, .os_tag = .windows },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build options
    const test_filter = b.option([]const u8, "test-filter", "Filter tests by name");
    const cross_compile = b.option(bool, "cross", "Build for all target platforms") orelse false;

    // Store exe for run step and tests (only used in non-cross mode)
    var default_exe: ?*std.Build.Step.Compile = null;
    var clap_mod_for_tests: ?*std.Build.Module = null;

    // Asset module (always created)
    const asset_mod = b.addModule("asset", .{
        .root_source_file = b.path("asset/root.zig"),
    });

    // Build options module (version info)
    const build_options = b.addOptions();
    // Read version from build.zig.zon
    const build_zon = @import("build.zig.zon");
    build_options.addOption([]const u8, "version", build_zon.version);
    const build_options_mod = build_options.createModule();

    if (cross_compile) {
        // Build for all targets
        for (cross_targets) |t| {
            const clap_dep = b.dependency("clap", .{
                .target = b.resolveTargetQuery(t),
                .optimize = optimize,
            });
            const clap_mod = clap_dep.module("clap");

            const exe = b.addExecutable(.{
                .name = "shgit",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("src/main.zig"),
                    .target = b.resolveTargetQuery(t),
                    .optimize = optimize,
                    .imports = &.{
                        .{ .name = "clap", .module = clap_mod },
                        .{ .name = "asset", .module = asset_mod },
                        .{ .name = "build_options", .module = build_options_mod },
                    },
                }),
            });

            const triple = t.zigTriple(b.allocator) catch @panic("failed to get triple");
            const target_output = b.addInstallArtifact(exe, .{
                .dest_dir = .{
                    .override = .{
                        .custom = triple,
                    },
                },
            });

            b.getInstallStep().dependOn(&target_output.step);
        }
    } else {
        // Default: build for current target only
        const clap_dep = b.dependency("clap", .{
            .target = target,
            .optimize = optimize,
        });
        const clap_mod = clap_dep.module("clap");
        clap_mod_for_tests = clap_mod;

        // Main executable
        const exe = b.addExecutable(.{
            .name = "shgit",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "clap", .module = clap_mod },
                    .{ .name = "asset", .module = asset_mod },
                    .{ .name = "build_options", .module = build_options_mod },
                },
            }),
        });

        b.installArtifact(exe);
        default_exe = exe;
    }

    // Run step (only available in default mode)
    if (default_exe) |exe| {
        const run_step = b.step("run", "Run shgit");
        const run_cmd = b.addRunArtifact(exe);
        run_step.dependOn(&run_cmd.step);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
    }

    // Tests (only available in default mode)
    if (clap_mod_for_tests) |_| {
        // Create shgit module for tests
        const shgit_mod = b.addModule("shgit", .{
            .root_source_file = b.path("src/root.zig"),
        });

        // Integration tests in test/
        const integration_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/main.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "shgit", .module = shgit_mod },
                },
            }),
            .filters = if (test_filter) |f| &.{f} else &.{},
        });
        const run_integration_tests = b.addRunArtifact(integration_tests);

        // Test step
        const test_step = b.step("test", "Run all tests");
        test_step.dependOn(&run_integration_tests.step);
    }
}

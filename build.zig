const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const test_filters: []const []const u8 = b.option(
        []const []const u8,
        "test-filter",
        "Skip tests that do not match any of the specified filters",
    ) orelse &.{};

    const uucode_dep = b.dependency("uucode", .{
        .target = target,
        .optimize = optimize,
        .extensions_0 = @as([]const []const u8, &.{
            "wcwidth",
        }),
        .fields_0 = @as([]const []const u8, &.{
            "is_emoji_vs_base",
            "grapheme_break",
            "wcwidth_standalone",
            "wcwidth_zero_in_grapheme",
        }),
    });

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        // need terminal syscall helpers that zig std doesn't provide (yet)
        .link_libc = true,
    });
    lib_mod.addImport("uucode", uucode_dep.module("uucode"));

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("quil", lib_mod);

    const lib = b.addLibrary(.{
        .name = "quil",
        .root_module = lib_mod,
        .linkage = .static,
    });
    b.installArtifact(lib);
    const lib_check = b.addLibrary(.{
        .name = "quil",
        .root_module = lib_mod,
        .linkage = .static,
    });

    const exe = b.addExecutable(.{
        .name = "quil",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);
    const exe_check = b.addExecutable(.{
        .name = "quil",
        .root_module = exe_mod,
    });

    // Check

    const check = b.step("check", "Check if it compiles");
    check.dependOn(&lib_check.step);
    check.dependOn(&exe_check.step);

    // Run

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Test

    const lib_unit_tests = b.addTest(.{
        .root_module = lib_mod,
        .filters = test_filters,
    });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
        .filters = test_filters,
    });
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
    // these are useful for running in profiler
    // test_step.dependOn(&b.addInstallArtifact(lib_unit_tests, .{}).step);
    // test_step.dependOn(&b.addInstallArtifact(exe_unit_tests, .{}).step);
}

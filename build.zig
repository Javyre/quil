const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const test_filters: []const []const u8 = b.option(
        []const []const u8,
        "test-filter",
        "Skip tests that do not match any of the specified filters",
    ) orelse &.{};

    const libuv_dep = b.dependency("zig_libuv", .{
        .target = target,
        .optimize = optimize,
    });

    const zg_dep = b.dependency("zg", .{
        .target = target,
        .optimize = optimize,
    });

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_mod.linkLibrary(libuv_dep.artifact("libuv"));
    lib_mod.addImport("uv", libuv_dep.module("uv"));
    lib_mod.addImport("zg_grapheme", zg_dep.module("grapheme"));
    lib_mod.addImport("zg_DisplayWidth", zg_dep.module("DisplayWidth"));
    lib_mod.addImport("zg_code_point", zg_dep.module("code_point"));
    lib_mod.addImport("zg_ascii", zg_dep.module("ascii"));

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("quil", lib_mod);

    const lib = b.addStaticLibrary(.{
        .name = "quil",
        .root_module = lib_mod,
    });
    b.installArtifact(lib);
    const lib_check = b.addStaticLibrary(.{
        .name = "quil",
        .root_module = lib_mod,
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

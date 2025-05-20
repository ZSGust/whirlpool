const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addStaticLibrary(.{
        .name = "whirlpool",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(lib);

    const lib_tests = b.addTest(.{
        .root_source_file = b.path("src/actor/actor.zig"),
        .target = target,
        .optimize = optimize,
    });

    const stress_tests = b.addTest(.{
        .name = "stress-tests",
        .root_source_file = b.path("tests/stress_tests.zig"),
        .target = target,
        .optimize = optimize,
    });

    stress_tests.addIncludePath(b.path("src"));

    const test_cmd = b.addRunArtifact(lib_tests);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&test_cmd.step);

    const stress_cmd = b.addRunArtifact(stress_tests);
    const stress_step = b.step("test-stress", "Run stress tests");
    stress_step.dependOn(&stress_cmd.step);
}

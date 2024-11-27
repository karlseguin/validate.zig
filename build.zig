const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const localize_module = b.dependency("localize", .{
        .target = target,
        .optimize = optimize,
    }).module("localize");

    _ = b.addModule("validate", .{
        .root_source_file = b.path("src/validate.zig"),
        .imports = &.{.{ .name = "localize", .module = localize_module }},
    });

    const lib_test = b.addTest(.{
        .root_source_file = b.path("src/validate.zig"),
        .target = target,
        .optimize = optimize,
        .test_runner = b.path("test_runner.zig"),
    });
    lib_test.root_module.addImport("localize", localize_module);

    const run_test = b.addRunArtifact(lib_test);
    run_test.has_side_effects = true;

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_test.step);
}

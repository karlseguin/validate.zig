const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const typed_module = b.dependency("typed", .{
        .target = target,
        .optimize = optimize,
    }).module("typed");

    const mod = b.addModule("validate", .{
        .root_source_file = b.path("src/validate.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "typed", .module = typed_module }},
    });

    const lib_test = b.addTest(.{
        .root_module = mod,
        .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
    });

    lib_test.root_module.addImport("typed", typed_module);

    const run_test = b.addRunArtifact(lib_test);
    run_test.has_side_effects = true;

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_test.step);
}

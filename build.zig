const std = @import("std");

pub fn build(b: *std.Build) !void {
	const target = b.standardTargetOptions(.{});
	const optimize = b.standardOptimizeOption(.{});

	_ = b.addModule("validate", .{
		.source_file = .{ .path = "src/validate.zig" },
	});

	const typed_module = b.dependency("typed", .{
		.target = target,
		.optimize = optimize,
	}).module("typed");

	const lib_test = b.addTest(.{
		.root_source_file = .{ .path = "src/validate.zig" },
		.target = target,
		.optimize = optimize,
	});

	lib_test.addModule("typed", typed_module);
	lib_test.addIncludePath("lib/regez");

	const run_test = b.addRunArtifact(lib_test);
	run_test.has_side_effects = true;

	const test_step = b.step("test", "Run tests");
	test_step.dependOn(&run_test.step);
}

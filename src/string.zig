const std = @import("std");
const t = @import("t.zig");

const v = @import("validate.zig");
const codes = @import("codes.zig");
const Context = @import("context.zig").Context;
const Validator = @import("validator.zig").Validator;

const INVALID_TYPE = v.Invalid{
	.code = codes.STRING_TYPE,
	.@"error" = "must be a string",
};

pub fn StringConfig(comptime _: type) type {
	return struct {
		min: ?usize = null,
		max: ?usize = null,
		required: bool = false,
	};
}

pub fn String(comptime S: type) type {
	return struct {
		required: bool,
		min: ?usize,
		max: ?usize,
		min_invalid: ?v.Invalid,
		max_invalid: ?v.Invalid,

		const Self = @This();

		pub fn validator(self: *const Self) Validator(S) {
			return Validator(S).init(self);
		}

		pub fn validateJson(self: *const Self, optional_value: ?std.json.Value, context: *Context(S)) !void {
			const untyped_value = optional_value orelse {
				if (self.required) {
					return context.add(v.required);
				}
				return;
			};

			const value = switch (untyped_value) {
				.String => |s| s,
				else => return context.add(INVALID_TYPE),
			};

			if (self.min) |m| {
				if (value.len < m) {
					return context.add(self.min_invalid.?);
				}
			}

			if (self.max) |m| {
				if (value.len > m) {
					return context.add(self.max_invalid.?);
				}
			}
		}
	};
}

pub fn stringS(comptime S: type, comptime config: StringConfig(S)) String(S) {
	var min_invalid: ?v.Invalid = null;
	if (config.min) |m| {
		min_invalid = v.Invalid{
			.code = codes.STRING_LEN_MIN,
			.data = .{.min = .{.min = m }},
			.@"error" = std.fmt.comptimePrint("must have at least {d} characters", .{m}),
		};
	}

	var max_invalid: ?v.Invalid = null;
	if (config.max) |m| {
		max_invalid = v.Invalid{
			.code = codes.STRING_LEN_MAX,
			.data = .{.max = .{.max = m }},
			.@"error" = std.fmt.comptimePrint("must no more than {d} characters", .{m}),
		};
	}

	return .{
		.min = config.min,
		.max = config.max,
		.min_invalid = min_invalid,
		.max_invalid = max_invalid,
		.required = config.required,
	};
}

pub fn string(comptime config: StringConfig(void)) String(void) {
	return stringS(void, config);
}

test "string: required" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_depth = 1}, {});
	defer context.deinit(t.allocator);

	try stringS(void, .{.required = true}).validateJson(null, &context);
	try t.expectInvalid(.{.code = codes.REQUIRED}, context);

	context.reset();
	try stringS(void, .{.required = false}).validateJson(null, &context);
	try t.expectEqual(true, context.isValid());
}

test "string: type" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_depth = 1}, {});
	defer context.deinit(t.allocator);

	try string(.{}).validateJson(.{.Integer = 33}, &context);
	try t.expectInvalid(.{.code = codes.STRING_TYPE}, context);
}

test "string: min length" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_depth = 1}, {});
	defer context.deinit(t.allocator);

	const s = string(.{.min = 4});

	{
		try s.validateJson(.{.String = "abc"}, &context);
		try t.expectInvalid(.{.code = codes.STRING_LEN_MIN, .data_min = 4}, context);
	}

	{
		context.reset();
		try s.validateJson(.{.String = "abcd"}, &context);
		try t.expectEqual(true, context.isValid());
	}

	{
		context.reset();
		try s.validateJson(.{.String = "abcde"}, &context);
		try t.expectEqual(true, context.isValid());
	}
}


test "string: max length" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_depth = 1}, {});
	defer context.deinit(t.allocator);

	const s = string(.{.max = 4});

	{
		try s.validateJson(.{.String = "abcde"}, &context);
		try t.expectInvalid(.{.code = codes.STRING_LEN_MAX, .data_max = 4}, context);
	}

	{
		context.reset();
		try s.validateJson(.{.String = "abcd"}, &context);
		try t.expectEqual(true, context.isValid());
	}

	{
		context.reset();
		try s.validateJson(.{.String = "abc"}, &context);
		try t.expectEqual(true, context.isValid());
	}
}

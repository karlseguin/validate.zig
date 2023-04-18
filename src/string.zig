const std = @import("std");
const t = @import("t.zig");

const v = @import("validate.zig");
const codes = @import("codes.zig");
const Context = @import("context.zig").Context;
const Validator = @import("validator.zig").Validator;

const json = std.json;
const Allocator = std.mem.Allocator;

const INVALID_TYPE = v.Invalid{
	.code = codes.STRING_TYPE,
	.err = "must be a string",
};

pub fn StringConfig(comptime S: type) type {
	return struct {
		min: ?usize = null,
		max: ?usize = null,
		required: bool = false,
		function: ?*const fn(value: []const u8, context: *Context(S)) anyerror!?[]const u8 = null,
	};
}

pub fn String(comptime S: type) type {
	return struct {
		required: bool,
		min: ?usize,
		max: ?usize,
		min_invalid: ?v.Invalid,
		max_invalid: ?v.Invalid,
		function: ?*const fn(value: []const u8, context: *Context(S)) anyerror!?[]const u8,

		const Self = @This();

		pub fn deinit(self: Self, allocator: Allocator) void {
			if (self.min_invalid) |i| {
				allocator.free(i.err);
			}

			if (self.max_invalid) |i| {
				allocator.free(i.err);
			}
		}

		pub fn validator(self: *const Self) Validator(S) {
			return Validator(S).init(self);
		}

		pub fn validateJsonValue(self: *const Self, input: ?json.Value, context: *Context(S)) !?json.Value {
			const untyped_value = input orelse {
				if (self.required) {
					try context.add(v.required);
				}
				return null;
			};

			const value = switch (untyped_value) {
				.String => |s| s,
				else => {
					try context.add(INVALID_TYPE);
					return null;
				}
			};

			if (self.min) |m| {
				std.debug.assert(self.min_invalid != null);
				if (value.len < m) {
					try context.add(self.min_invalid.?);
					return null;
				}
			}

			if (self.max) |m| {
				std.debug.assert(self.max_invalid != null);
				if (value.len > m) {
					try context.add(self.max_invalid.?);
					return null;
				}
			}

			if (self.function) |f| {
				const transformed = try f(value, context) orelse return null;
				return json.Value{.String = transformed};
			}

			return null;
		}
	};
}

pub fn string(comptime S: type, allocator: Allocator, config: StringConfig(S)) !String(S) {
	var min_invalid: ?v.Invalid = null;
	if (config.min) |m| {
		min_invalid = v.Invalid{
			.code = codes.STRING_LEN_MIN,
			.data = .{.imin = .{.min = @intCast(i64, m) }},
			.err = try std.fmt.allocPrint(allocator, "must have at least {d} characters", .{m}),
		};
	}

	var max_invalid: ?v.Invalid = null;
	if (config.max) |m| {
		max_invalid = v.Invalid{
			.code = codes.STRING_LEN_MAX,
			.data = .{.imax = .{.max = @intCast(i64, m) }},
			.err = try std.fmt.allocPrint(allocator, "must no more than {d} characters", .{m}),
		};
	}

	return .{
		.min = config.min,
		.max = config.max,
		.min_invalid = min_invalid,
		.max_invalid = max_invalid,
		.required = config.required,
		.function = config.function,
	};
}

const nullJson = @as(?json.Value, null);
test "string: required" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_depth = 1}, {});
	defer context.deinit(t.allocator);

	{
		const validator = try string(void, t.allocator, .{.required = true});
		try t.expectEqual(nullJson, try validator.validateJsonValue(null, &context));
		try t.expectInvalid(.{.code = codes.REQUIRED}, context);
	}

	{
		context.reset();
		const validator = try string(void, t.allocator, .{.required = false});
		try t.expectEqual(nullJson, try validator.validateJsonValue(null, &context));
		try t.expectEqual(true, context.isValid());
	}
}

test "string: type" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_depth = 1}, {});
	defer context.deinit(t.allocator);

	const validator = try string(void, t.allocator, .{});
	try t.expectEqual(nullJson, try validator.validateJsonValue(.{.Integer = 33}, &context));
	try t.expectInvalid(.{.code = codes.STRING_TYPE}, context);
}

test "string: min length" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_depth = 1}, {});
	defer context.deinit(t.allocator);

	const validator = try string(void, t.allocator, .{.min = 4});
	defer validator.deinit(t.allocator);

	{
		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.String = "abc"}, &context));
		try t.expectInvalid(.{.code = codes.STRING_LEN_MIN, .data_min = 4}, context);
	}

	{
		context.reset();
		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.String = "abcd"}, &context));
		try t.expectEqual(true, context.isValid());
	}

	{
		context.reset();
		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.String = "abcde"}, &context));
		try t.expectEqual(true, context.isValid());
	}
}


test "string: max length" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_depth = 1}, {});
	defer context.deinit(t.allocator);

	const validator = try string(void, t.allocator, .{.max = 4});
	defer validator.deinit(t.allocator);

	{
		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.String = "abcde"}, &context));
		try t.expectInvalid(.{.code = codes.STRING_LEN_MAX, .data_max = 4}, context);
	}

	{
		context.reset();
		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.String = "abcd"}, &context));
		try t.expectEqual(true, context.isValid());
	}

	{
		context.reset();
		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.String = "abc"}, &context));
		try t.expectEqual(true, context.isValid());
	}
}

test "string: function" {
	var context = try Context(i64).init(t.allocator, .{.max_errors = 2, .max_depth = 1}, 101);
	defer context.deinit(t.allocator);

	const validator = try string(i64, t.allocator, .{.function = testStringValidator});
	defer validator.deinit(t.allocator);

	{
		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.String = "ok"}, &context));
		try t.expectEqual(true, context.isValid());
	}

	{
		context.reset();
		try t.expectString("19", (try validator.validateJsonValue(.{.String = "change"}, &context)).?.String);
		try t.expectEqual(true, context.isValid());
	}

	{
		context.reset();
		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.String = "fail"}, &context));
		try t.expectInvalid(.{.code = 999, .err = "string validation error"}, context);
	}
}

fn testStringValidator(value: []const u8, context: *Context(i64)) !?[]const u8 {
	std.debug.assert(context.state == 101);

	if (std.mem.eql(u8, value, "change")) {
		// test the arena allocator while we're here
		var alt = try context.allocator.alloc(u8, 2);
		alt[0] = '1';
		alt[1] = '9';
		return alt;
	}

	if (std.mem.eql(u8, value, "fail")) {
		try context.add(v.Invalid{
			.code = 999,
			.err = "string validation error",
		});
		return null;
	}

	return null;
}

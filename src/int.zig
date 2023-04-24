const std = @import("std");
const t = @import("t.zig");

const v = @import("validate.zig");
const codes = @import("codes.zig");
const Builder = @import("builder.zig").Builder;
const Context = @import("context.zig").Context;
const Validator = @import("validator.zig").Validator;

const json = std.json;
const Allocator = std.mem.Allocator;

const INVALID_TYPE = v.Invalid{
	.code = codes.TYPE_INT,
	.err = "must be an int",
};

pub fn Int(comptime S: type) type {
	return struct {
		required: bool,
		min: ?i64,
		max: ?i64,
		min_invalid: ?v.Invalid,
		max_invalid: ?v.Invalid,
		function: ?*const fn(value: ?i64, context: *Context(S)) anyerror!?i64,

		const Self = @This();

		pub const Config = struct {
			min: ?i64 = null,
			max: ?i64 = null,
			required: bool = false,
			function: ?*const fn(value: ?i64, context: *Context(S)) anyerror!?i64 = null,
		};

		pub fn init(allocator: Allocator, config: Config) !Self {
			var min_invalid: ?v.Invalid = null;
			if (config.min) |m| {
				min_invalid = v.Invalid{
					.code = codes.INT_MIN,
					.data = .{.imin = .{.min = m }},
					.err = try std.fmt.allocPrint(allocator, "cannot be less than {d}", .{m}),
				};
			}

			var max_invalid: ?v.Invalid = null;
			if (config.max) |m| {
				max_invalid = v.Invalid{
					.code = codes.INT_MAX,
					.data = .{.imax = .{.max = m }},
					.err = try std.fmt.allocPrint(allocator, "cannot be greater than {d}", .{m}),
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

		pub fn validator(self: *Self) Validator(S) {
			return Validator(S).init(self);
		}

		// part of the Validator interface, but noop for ints
		pub fn nestField(_: *Self, _: Allocator, _: *v.Field(S)) !void {}

		pub fn validateJsonValue(self: *const Self, input: ?json.Value, context: *Context(S)) !?json.Value {
			const untyped_value = input orelse {
				if (self.required) {
					try context.add(v.required);
				}
				return self.executeFunction(null, context);
			};

			const value = switch (untyped_value) {
				.Integer => |n| n,
				else => {
					try context.add(INVALID_TYPE);
					return null;
				}
			};

			if (self.min) |m| {
				std.debug.assert(self.min_invalid != null);
				if (value < m) {
					try context.add(self.min_invalid.?);
					return null;
				}
			}

			if (self.max) |m| {
				std.debug.assert(self.max_invalid != null);
				if (value > m) {
					try context.add(self.max_invalid.?);
					return null;
				}
			}

			return self.executeFunction(value, context);
		}

		fn executeFunction(self: *const Self, value: ?i64, context: *Context(S)) !?json.Value {
			if (self.function) |f| {
				const transformed = try f(value, context) orelse return null;
				return json.Value{.Integer = transformed};
			}
			return null;
		}
	};
}

const nullJson = @as(?json.Value, null);
test "int: required" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 1}, {});
	defer context.deinit(t.allocator);

	const builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	{
		const validator = builder.int(.{.required = true});
		try t.expectEqual(nullJson, try validator.validateJsonValue(null, &context));
		try t.expectInvalid(.{.code = codes.REQUIRED}, context);
	}

	{
		t.reset(&context);
		const validator = builder.int(.{.required = false});
		try t.expectEqual(nullJson, try validator.validateJsonValue(null, &context));
		try t.expectEqual(true, context.isValid());
	}
}

test "int: type" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 1}, {});
	defer context.deinit(t.allocator);

	const builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const validator = builder.int(.{});
	try t.expectEqual(nullJson, try validator.validateJsonValue(.{.String = "NOPE"}, &context));
	try t.expectInvalid(.{.code = codes.TYPE_INT}, context);
}

test "int: min" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 1}, {});
	defer context.deinit(t.allocator);

	const builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const validator = builder.int(.{.min = 4});
	{
		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.Integer = 3}, &context));
		try t.expectInvalid(.{.code = codes.INT_MIN, .data_min = 4}, context);
	}

	{
		t.reset(&context);
		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.Integer = 4}, &context));
		try t.expectEqual(true, context.isValid());
	}

	{
		t.reset(&context);
		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.Integer = 100}, &context));
		try t.expectEqual(true, context.isValid());
	}
}


test "int: max" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 1}, {});
	defer context.deinit(t.allocator);

	const builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const validator = builder.int(.{.max = 4});

	{
		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.Integer = 5}, &context));
		try t.expectInvalid(.{.code = codes.INT_MAX, .data_max = 4}, context);
	}

	{
		t.reset(&context);
		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.Integer = 4}, &context));
		try t.expectEqual(true, context.isValid());
	}

	{
		t.reset(&context);
		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.Integer = -30}, &context));
		try t.expectEqual(true, context.isValid());
	}
}

test "int: function" {
	var context = try Context(i64).init(t.allocator, .{.max_errors = 2, .max_nesting = 1}, 101);
	defer context.deinit(t.allocator);

	const builder = try Builder(i64).init(t.allocator);
	defer builder.deinit(t.allocator);

	const validator = builder.int(.{.function = testIntValidator});

	{
		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.Integer = 99}, &context));
		try t.expectEqual(true, context.isValid());
	}

	{
		try t.expectEqual(@as(i64, -9999), (try validator.validateJsonValue(null, &context)).?.Integer);
		try t.expectEqual(true, context.isValid());
	}

	{
		t.reset(&context);
		try t.expectEqual(@as(i64, -38291), (try validator.validateJsonValue(.{.Integer = 2}, &context)).?.Integer);
		try t.expectEqual(true, context.isValid());
	}

	{
		t.reset(&context);
		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.Integer = 3}, &context));
		try t.expectInvalid(.{.code = 998, .err = "int validation error"}, context);
	}
}

fn testIntValidator(value: ?i64, context: *Context(i64)) !?i64 {
	std.debug.assert(context.state == 101);

	const n = value orelse return -9999;

	if (n == 2) {
		return -38291;
	}

	if (n == 3) {
		try context.add(v.Invalid{
			.code = 998,
			.err = "int validation error",
		});
		return null;
	}

	return null;
}

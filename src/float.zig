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
	.code = codes.TYPE_FLOAT,
	.err = "must be a float",
};

pub fn Float(comptime S: type) type {
	return struct {
		required: bool,
		min: ?f64,
		max: ?f64,
		strict: bool,
		min_invalid: ?v.Invalid,
		max_invalid: ?v.Invalid,
		function: ?*const fn(value: ?f64, context: *Context(S)) anyerror!?f64,

		const Self = @This();

		pub const Config = struct {
			min: ?f64 = null,
			max: ?f64 = null,
			strict: bool = false,
			required: bool = false,
			function: ?*const fn(value: ?f64, context: *Context(S)) anyerror!?f64 = null,
		};

		pub fn init(allocator: Allocator, config: Config) !Self {
			var min_invalid: ?v.Invalid = null;
			if (config.min) |m| {
				min_invalid = v.Invalid{
					.code = codes.FLOAT_MIN,
					.data = .{.fmin = .{.min = m }},
					.err = try std.fmt.allocPrint(allocator, "cannot be less than {d}", .{m}),
				};
			}

			var max_invalid: ?v.Invalid = null;
			if (config.max) |m| {
				max_invalid = v.Invalid{
					.code = codes.FLOAT_MAX,
					.data = .{.fmax = .{.max = m }},
					.err = try std.fmt.allocPrint(allocator, "cannot be greater than {d}", .{m}),
				};
			}

			return .{
				.min = config.min,
				.max = config.max,
				.strict = config.strict,
				.min_invalid = min_invalid,
				.max_invalid = max_invalid,
				.required = config.required,
				.function = config.function,
			};
		}

		pub fn validator(self: *Self) Validator(S) {
			return Validator(S).init(self);
		}

		pub fn trySetRequired(self: *Self, req: bool, builder: *Builder(S)) !*Float(S) {
			var clone = try builder.allocator.create(Float(S));
			clone.* = self.*;
			clone.required = req;
			return clone;
		}
		pub fn setRequired(self: *Self, req: bool, builder: *Builder(S)) *Float(S) {
			return self.trySetRequired(req, builder) catch unreachable;
		}

		// part of the Validator interface, but noop for floats
		pub fn nestField(_: *Self, _: Allocator, _: *v.Field(S)) !void {}

		pub fn validateJsonValue(self: *const Self, input: ?json.Value, context: *Context(S)) !?json.Value {
			const untyped_value = input orelse {
				if (self.required) {
					try context.add(v.required);
				}
				return self.executeFunction(null, context);
			};

			const value = switch (untyped_value) {
				.Float => |f| f,
				.Integer => |n| blk: {
					if (self.strict) {
						try context.add(INVALID_TYPE);
						return null;
					}
					break :blk @intToFloat(f64, n);
				},
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

		fn executeFunction(self: *const Self, value: ?f64, context: *Context(S)) !?json.Value {
			if (self.function) |f| {
				const transformed = try f(value, context) orelse return null;
				return json.Value{.Float = transformed};
			}
			return null;
		}
	};
}

const nullJson = @as(?json.Value, null);
test "float: required" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 1}, {});
	defer context.deinit(t.allocator);

	var builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const notRequired = builder.float(.{.required = false, });
	const required = notRequired.setRequired(true, &builder);

	{
		try t.expectEqual(nullJson, try required.validateJsonValue(null, &context));
		try t.expectInvalid(.{.code = codes.REQUIRED}, context);
	}

	{
		t.reset(&context);
		try t.expectEqual(nullJson, try notRequired.validateJsonValue(null, &context));
		try t.expectEqual(true, context.isValid());
	}

	{
		// test required = false when configured directly (not via setRequired)
		t.reset(&context);
		const validator = builder.float(.{.required = false});
		try t.expectEqual(nullJson, try validator.validateJsonValue(null, &context));
		try t.expectEqual(true, context.isValid());
	}
}

test "float: type" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 1}, {});
	defer context.deinit(t.allocator);

	const builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const validator = builder.float(.{});
	try t.expectEqual(nullJson, try validator.validateJsonValue(.{.String = "NOPE"}, &context));
	try t.expectInvalid(.{.code = codes.TYPE_FLOAT}, context);
}

test "float: strict" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 1}, {});
	defer context.deinit(t.allocator);

	const builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const validator = builder.float(.{.strict = true});

	{
		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.Float = 4.1}, &context));
		try t.expectEqual(true, context.isValid());
	}

	{
		t.reset(&context);
		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.Integer = 99}, &context));
		try t.expectInvalid(.{.code = codes.TYPE_FLOAT}, context);
	}
}

test "float: not strict" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 1}, {});
	defer context.deinit(t.allocator);

	const builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const validator = builder.float(.{});

	{
		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.Float = 4.1}, &context));
		try t.expectEqual(true, context.isValid());
	}

	{
		t.reset(&context);
		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.Integer = 99}, &context));
		try t.expectEqual(true, context.isValid());
	}
}

test "float: min" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 1}, {});
	defer context.deinit(t.allocator);

	const builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const validator = builder.float(.{.min = 4.2});
	{
		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.Float = 4.1}, &context));
		try t.expectInvalid(.{.code = codes.FLOAT_MIN, .data_fmin = 4.2, .err = "cannot be less than 4.2"}, context);
	}

	{
		t.reset(&context);
		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.Float = 4.2}, &context));
		try t.expectEqual(true, context.isValid());
	}

	{
		t.reset(&context);
		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.Float = 293.2}, &context));
		try t.expectEqual(true, context.isValid());
	}
}

test "float: max" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 1}, {});
	defer context.deinit(t.allocator);

	const builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const validator = builder.float(.{.max = 4.1});

	{
		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.Float = 4.2}, &context));
		try t.expectInvalid(.{.code = codes.FLOAT_MAX, .data_fmax = 4.1}, context);
	}

	{
		t.reset(&context);
		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.Float = 4.1}, &context));
		try t.expectEqual(true, context.isValid());
	}

	{
		t.reset(&context);
		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.Float = -33.2}, &context));
		try t.expectEqual(true, context.isValid());
	}
}

test "float: function" {
	var context = try Context(f64).init(t.allocator, .{.max_errors = 2, .max_nesting = 1}, 101);
	defer context.deinit(t.allocator);

	const builder = try Builder(f64).init(t.allocator);
	defer builder.deinit(t.allocator);

	const validator = builder.float(.{.function = testFloatValidator});

	{
		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.Float = 99.1}, &context));
		try t.expectEqual(true, context.isValid());
	}

	{
		try t.expectEqual(@as(f64, -9999.88), (try validator.validateJsonValue(null, &context)).?.Float);
		try t.expectEqual(true, context.isValid());
	}

	{
		t.reset(&context);
		try t.expectEqual(@as(f64, -38291.2), (try validator.validateJsonValue(.{.Float = 2.1}, &context)).?.Float);
		try t.expectEqual(true, context.isValid());
	}

	{
		t.reset(&context);
		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.Float = 3.2}, &context));
		try t.expectInvalid(.{.code = 997, .err = "float validation error"}, context);
	}
}

fn testFloatValidator(value: ?f64, context: *Context(f64)) !?f64 {
	std.debug.assert(context.state == 101);

	const f = value orelse return -9999.88;

	if (f == 2.1) {
		return -38291.2;
	}

	if (f == 3.2) {
		try context.add(v.Invalid{
			.code = 997,
			.err = "float validation error",
		});
		return null;
	}

	return null;
}

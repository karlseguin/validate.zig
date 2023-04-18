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
	.err = "must be an float",
};

pub fn Float(comptime S: type) type {
	return struct {
		required: bool,
		min: ?f64,
		max: ?f64,
		min_invalid: ?v.Invalid,
		max_invalid: ?v.Invalid,
		function: ?*const fn(value: f64, context: *Context(S)) anyerror!?f64,

		const Self = @This();

		pub const Config = struct {
			min: ?f64 = null,
			max: ?f64 = null,
			required: bool = false,
			function: ?*const fn(value: f64, context: *Context(S)) anyerror!?f64 = null,
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
				.min_invalid = min_invalid,
				.max_invalid = max_invalid,
				.required = config.required,
				.function = config.function,
			};
		}

		pub fn validator(self: *const Self) Validator(S) {
			return Validator(S).init(self);
		}

		// part of the Validator interface, but noop for ints
		pub fn nestField(_: *const Self, _: Allocator, _: []const u8) !void {}

		pub fn validateJsonValue(self: *const Self, input: ?json.Value, context: *Context(S)) !?json.Value {
			const untyped_value = input orelse {
				if (self.required) {
					try context.add(v.required);
				}
				return null;
			};

			const value = switch (untyped_value) {
				.Float => |f| f,
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
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_depth = 1}, {});
	defer context.deinit(t.allocator);

	const builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	{
		const validator = try builder.float(.{.required = true});
		try t.expectEqual(nullJson, try validator.validateJsonValue(null, &context));
		try t.expectInvalid(.{.code = codes.REQUIRED}, context);
	}

	{
		context.reset();
		const validator = try builder.float(.{.required = false});
		try t.expectEqual(nullJson, try validator.validateJsonValue(null, &context));
		try t.expectEqual(true, context.isValid());
	}
}

test "float: type" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_depth = 1}, {});
	defer context.deinit(t.allocator);

	const builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const validator = try builder.float(.{});
	try t.expectEqual(nullJson, try validator.validateJsonValue(.{.String = "NOPE"}, &context));
	try t.expectInvalid(.{.code = codes.TYPE_FLOAT}, context);
}

test "float: min" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_depth = 1}, {});
	defer context.deinit(t.allocator);

	const builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const validator = try builder.float(.{.min = 4.2});
	{
		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.Float = 4.1}, &context));
		try t.expectInvalid(.{.code = codes.FLOAT_MIN, .data_fmin = 4.2}, context);
	}

	{
		context.reset();
		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.Float = 4.2}, &context));
		try t.expectEqual(true, context.isValid());
	}

	{
		context.reset();
		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.Float = 293.2}, &context));
		try t.expectEqual(true, context.isValid());
	}
}

test "float: max" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_depth = 1}, {});
	defer context.deinit(t.allocator);

	const builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const validator = try builder.float(.{.max = 4.1});

	{
		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.Float = 4.2}, &context));
		try t.expectInvalid(.{.code = codes.FLOAT_MAX, .data_fmax = 4.1}, context);
	}

	{
		context.reset();
		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.Float = 4.1}, &context));
		try t.expectEqual(true, context.isValid());
	}

	{
		context.reset();
		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.Float = -33.2}, &context));
		try t.expectEqual(true, context.isValid());
	}
}

test "float: function" {
	var context = try Context(f64).init(t.allocator, .{.max_errors = 2, .max_depth = 1}, 101);
	defer context.deinit(t.allocator);

	const builder = try Builder(f64).init(t.allocator);
	defer builder.deinit(t.allocator);

	const validator = try builder.float(.{.function = testFloatValidator});

	{
		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.Float = 99.1}, &context));
		try t.expectEqual(true, context.isValid());
	}

	{
		context.reset();
		try t.expectEqual(@as(f64, -38291.2), (try validator.validateJsonValue(.{.Float = 2.1}, &context)).?.Float);
		try t.expectEqual(true, context.isValid());
	}

	{
		context.reset();
		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.Float = 3.2}, &context));
		try t.expectInvalid(.{.code = 997, .err = "float validation error"}, context);
	}
}

fn testFloatValidator(value: f64, context: *Context(f64)) !?f64 {
	std.debug.assert(context.state == 101);

	if (value == 2.1) {
		return -38291.2;
	}

	if (value == 3.2) {
		try context.add(v.Invalid{
			.code = 997,
			.err = "float validation error",
		});
		return null;
	}

	return null;
}

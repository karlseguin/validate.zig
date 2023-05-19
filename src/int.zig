const std = @import("std");
const typed = @import("typed");

const v = @import("validate.zig");
const codes = @import("codes.zig");
const Builder = @import("builder.zig").Builder;
const Context = @import("context.zig").Context;
const Validator = @import("validator.zig").Validator;

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
		parse: bool,
		min_invalid: ?v.Invalid,
		max_invalid: ?v.Invalid,
		function: ?*const fn(value: ?i64, context: *Context(S)) anyerror!?i64,

		const Self = @This();

		pub const Config = struct {
			min: ?i64 = null,
			max: ?i64 = null,
			parse: bool = false,
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
				.parse = config.parse,
				.min_invalid = min_invalid,
				.max_invalid = max_invalid,
				.required = config.required,
				.function = config.function,
			};
		}

		pub fn validator(self: *Self) Validator(S) {
			return Validator(S).init(self);
		}

		pub fn trySetRequired(self: *Self, req: bool, builder: *Builder(S)) !*Int(S) {
			var clone = try builder.allocator.create(Int(S));
			clone.* = self.*;
			clone.required = req;
			return clone;
		}
		pub fn setRequired(self: *Self, req: bool, builder: *Builder(S)) *Int(S) {
			return self.trySetRequired(req, builder) catch unreachable;
		}

		// part of the Validator interface, but noop for ints
		pub fn nestField(_: *Self, _: Allocator, _: *v.Field) !void {}

		pub fn validateValue(self: *const Self, input: ?typed.Value, context: *Context(S)) !typed.Value {
			var int_value: ?i64 = null;
			if (input) |untyped_value| {
				int_value = switch (untyped_value) {
					.i64 => |n| @intCast(i64, n),
					.i8 => |n| @intCast(i64, n),
					.i16 => |n| @intCast(i64, n),
					.i32 => |n| @intCast(i64, n),
					.u8 => |n| @intCast(i64, n),
					.u16 => |n| @intCast(i64, n),
					.u32 => |n| @intCast(i64, n),
					.string => |s| blk: {
						if (self.parse) {
							const val = std.fmt.parseInt(i64, s, 10) catch {
								try context.add(INVALID_TYPE);
								return .{.null = {}};
							};
							break :blk val;
						}
						try context.add(INVALID_TYPE);
						return .{.null = {}};
					},
					else => {
						try context.add(INVALID_TYPE);
						return .{.null = {}};
					}
				};
			}

			if (try self.validate(int_value, context)) |value| {
				return .{.i64 = value};
			}
			return .{.null = {}};
		}

		pub fn validate(self: *const Self, optional_value: ?i64, context: *Context(S)) !?i64 {
			const value = optional_value orelse {
				if (self.required) {
					try context.add(v.required);
					return null;
				}
				return self.executeFunction(null, context);
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

		fn executeFunction(self: *const Self, value: ?i64, context: *Context(S)) !?i64 {
			if (self.function) |f| {
				return f(value, context);
			}
			return value;
		}
	};
}

const t = @import("t.zig");
const nullValue = typed.Value{.null = {}};
test "int: required" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 1}, {});
	defer context.deinit(t.allocator);

	var builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const notRequired = builder.int(.{.required = false, });
	const required = notRequired.setRequired(true, &builder);

	{
		try t.expectEqual(nullValue, try required.validateValue(null, &context));
		try t.expectInvalid(.{.code = codes.REQUIRED}, context);
	}

	{
		t.reset(&context);
		try t.expectEqual(nullValue, try notRequired.validateValue(null, &context));
		try t.expectEqual(true, context.isValid());
	}

	{
		// test required = false when configured directly (not via setRequired)
		t.reset(&context);
		const validator = builder.int(.{.required = false});
		try t.expectEqual(nullValue, try validator.validateValue(null, &context));
		try t.expectEqual(true, context.isValid());
	}
}

test "int: type" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 1}, {});
	defer context.deinit(t.allocator);

	const builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const validator = builder.int(.{});
	try t.expectEqual(nullValue, try validator.validateValue(.{.string = "NOPE"}, &context));
	try t.expectInvalid(.{.code = codes.TYPE_INT}, context);
}

test "int: min" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 1}, {});
	defer context.deinit(t.allocator);

	const builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const validator = builder.int(.{.min = 4});
	{
		try t.expectEqual(nullValue, try validator.validateValue(.{.i64 = 3}, &context));
		try t.expectInvalid(.{.code = codes.INT_MIN, .data_min = 4}, context);
	}

	{
		t.reset(&context);
		try t.expectEqual(typed.Value{.i64 = 4}, try validator.validateValue(.{.i64 = 4}, &context));
		try t.expectEqual(true, context.isValid());
	}

	{
		t.reset(&context);
		try t.expectEqual(typed.Value{.i64 = 100}, try validator.validateValue(.{.i64 = 100}, &context));
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
		try t.expectEqual(nullValue, try validator.validateValue(.{.i64 = 5}, &context));
		try t.expectInvalid(.{.code = codes.INT_MAX, .data_max = 4}, context);
	}

	{
		t.reset(&context);
		try t.expectEqual(typed.Value{.i64 = 4}, try validator.validateValue(.{.i64 = 4}, &context));
		try t.expectEqual(true, context.isValid());
	}

	{
		t.reset(&context);
		try t.expectEqual(typed.Value{.i64 = -30}, try validator.validateValue(.{.i64 = -30}, &context));
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
		try t.expectEqual(nullValue, try validator.validateValue(.{.i64 = 99}, &context));
		try t.expectEqual(true, context.isValid());
	}

	{
		try t.expectEqual(@as(i64, -9999), (try validator.validateValue(null, &context)).i64);
		try t.expectEqual(true, context.isValid());
	}

	{
		t.reset(&context);
		try t.expectEqual(@as(i64, -38291), (try validator.validateValue(.{.i64 = 2}, &context)).i64);
		try t.expectEqual(true, context.isValid());
	}

	{
		t.reset(&context);
		try t.expectEqual(nullValue, try validator.validateValue(.{.i64 = 3}, &context));
		try t.expectInvalid(.{.code = 998, .err = "int validation error"}, context);
	}
}

test "int: parse" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 1}, {});
	defer context.deinit(t.allocator);

	const builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const validator = builder.int(.{.max = 4, .parse = true});

	{
		// still works fine with correct type
		try t.expectEqual(nullValue, try validator.validateValue(.{.i64 = 5}, &context));
		try t.expectInvalid(.{.code = codes.INT_MAX, .data_max = 4}, context);
	}

	{
		// parses a string and applies the validation on the parsed value
		t.reset(&context);
		try t.expectEqual(nullValue, try validator.validateValue(.{.string = "5"}, &context));
		try t.expectInvalid(.{.code = codes.INT_MAX, .data_max = 4}, context);
	}

	{
		// parses a string and returns the typed value
		t.reset(&context);
		try t.expectEqual(@as(i64, 3), (try validator.validateValue(.{.string = "3"}, &context)).i64);
		try t.expectEqual(true, context.isValid());
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

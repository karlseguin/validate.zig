const std = @import("std");
const typed = @import("typed");
const v = @import("validate.zig");

const codes = v.codes;
const Builder = v.Builder;
const Context = v.Context;
const Validator = v.Validator;
const DataBuilder = v.DataBuilder;

const Allocator = std.mem.Allocator;

const INVALID_TYPE = v.Invalid{
	.code = codes.TYPE_FLOAT,
	.err = "must be a float",
};

pub fn Float(comptime T: type, comptime S: type) type {
	if (@typeInfo(T) != .Float) {
		@compileError(@typeName(T) ++ " is not a float");
	}
	if (@typeInfo(T).Float.bits > 64) {
		@compileError("float validator does not support floats wider than 64 bits");
	}

	return struct {
		required: bool,
		min: ?T,
		max: ?T,
		parse: bool,
		strict: bool,
		bit_invalid: v.Invalid,
		min_invalid: ?v.Invalid,
		max_invalid: ?v.Invalid,
		function: ?*const fn(value: ?T, context: *Context(S)) anyerror!?T,

		const Self = @This();

		pub const Config = struct {
			min: ?T = null,
			max: ?T = null,
			parse: bool = false,
			strict: bool = false,
			required: bool = false,
			function: ?*const fn(value: ?T, context: *Context(S)) anyerror!?T = null,
		};

		pub fn init(allocator: Allocator, config: Config) !Self {
			var min_invalid: ?v.Invalid = null;
			if (config.min) |m| {
				min_invalid = v.Invalid{
					.code = codes.FLOAT_MIN,
					.data = try DataBuilder.init(allocator).put("min", m).done(),
					.err = try std.fmt.allocPrint(allocator, "cannot be less than {d}", .{m}),
				};
			}

			var max_invalid: ?v.Invalid = null;
			if (config.max) |m| {
				max_invalid = v.Invalid{
					.code = codes.FLOAT_MAX,
					.data = try DataBuilder.init(allocator).put("max", m).done(),
					.err = try std.fmt.allocPrint(allocator, "cannot be greater than {d}", .{m}),
				};
			}

			const bit_invalid = v.Invalid{
				.code = codes.INT_BIT,
				.data = try DataBuilder.init(allocator).put("type", @typeName(T)).done(),
				.err = try std.fmt.allocPrint(allocator, "is not a valid float type", .{}),
			};

			return .{
				.min = config.min,
				.max = config.max,
				.parse = config.parse,
				.strict = config.strict,
				.bit_invalid = bit_invalid,
				.min_invalid = min_invalid,
				.max_invalid = max_invalid,
				.required = config.required,
				.function = config.function,
			};
		}

		pub fn validator(self: *Self) Validator(S) {
			return Validator(S).init(self);
		}

		pub fn trySetRequired(self: *Self, req: bool, builder: *Builder(S)) !*Float(T, S) {
			var clone = try builder.allocator.create(Float(T, S));
			clone.* = self.*;
			clone.required = req;
			return clone;
		}
		pub fn setRequired(self: *Self, req: bool, builder: *Builder(S)) *Float(T, S) {
			return self.trySetRequired(req, builder) catch unreachable;
		}

		// part of the Validator interface, but noop for floats
		pub fn nestField(_: *Self, _: Allocator, _: *v.Field) !void {}

		pub fn validateValue(self: *const Self, input: ?typed.Value, context: *Context(S)) !typed.Value {
			var float_value: ?T = null;
			if (input) |untyped_value| {
				const bits =  @typeInfo(T).Float.bits;

				var valid = false;
				switch (untyped_value) {
					.f64 => |f| {
						if (bits >= 64) {
							float_value = @floatCast(T, f);
							valid = true;
						}
					},
					.f32 => |f| {
						if (bits >= 32) {
							float_value = @floatCast(T, f);
							valid = true;
						}
					},
					.string => |s| blk: {
						if (self.parse) {
							float_value = std.fmt.parseFloat(T, s) catch break :blk;
							valid = true;
						}
					},
					else => {
						if (!self.strict) {
							switch (untyped_value) {
								.i8 => |n| {
									float_value = @intToFloat(T, n);
									valid = true;
								},
								.i16 => |n| {
									float_value = @intToFloat(T, n);
									valid = true;
								},
								.i32 => |n| {
									float_value = @intToFloat(T, n);
									valid = true;
								},
								.i64 => |n| {
									float_value = @intToFloat(T, n);
									valid = true;
								},
								.i128 => |n| {
									float_value = @intToFloat(T, n);
									valid = true;
								},
								.u8 => |n| {
									float_value = @intToFloat(T, n);
									valid = true;
								},
								.u16 => |n| {
									float_value = @intToFloat(T, n);
									valid = true;
								},
								.u32 => |n| {
									float_value = @intToFloat(T, n);
									valid = true;
								},
								.u64 => |n| {
									float_value = @intToFloat(T, n);
									valid = true;
								},
								.u128 => |n| {
									float_value = @intToFloat(T, n);
									valid = true;
								},
								else => {},
							}
						}
					}
				}

				if (!valid) {
					switch (untyped_value) {
						.f32, .f64 => try context.add(self.bit_invalid),
						else => try context.add(INVALID_TYPE),
					}
					return .{.null = {}};
				}
			}

			if (try self.validate(float_value, context)) |value| {
				return typed.new(value);
			}
			return .{.null = {}};
		}

		pub fn validateString(self: *const Self, input: ?[]const u8, context: *Context(S)) !?T {
			var int_value: ?T = null;
			if (input) |string_value| {
				int_value = std.fmt.parseFloat(T, string_value,) catch {
					try context.add(INVALID_TYPE);
					return null;
				};
			}
			return self.validate(int_value, context);
		}

		pub fn validate(self: *const Self, optional_value: ?T, context: *Context(S)) !?T {
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

		fn executeFunction(self: *const Self, value: ?T, context: *Context(S)) !?T {
			if (self.function) |f| {
				return f(value, context);
			}
			return value;
		}
	};
}

const t = @import("t.zig");
const nullValue = typed.Value{.null = {}};
test "float: required" {
	var context = t.context();
	defer context.deinit(t.allocator);

	var builder = t.builder();
	defer builder.deinit(t.allocator);

	const notRequired = builder.float(f64, .{.required = false, });
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
		const validator = builder.float(f64, .{.required = false});
		try t.expectEqual(nullValue, try validator.validateValue(null, &context));
		try t.expectEqual(true, context.isValid());
	}
}

test "float: type" {
	var context = t.context();
	defer context.deinit(t.allocator);

	var builder = t.builder();
	defer builder.deinit(t.allocator);

	const validator = builder.float(f64, .{});
	try t.expectEqual(nullValue, try validator.validateValue(.{.string = "NOPE"}, &context));
	try t.expectInvalid(.{.code = codes.TYPE_FLOAT}, context);
}

test "float: strict" {
	var context = t.context();
	defer context.deinit(t.allocator);

	var builder = t.builder();
	defer builder.deinit(t.allocator);

	const validator = builder.float(f64, .{.strict = true});

	{
		try t.expectEqual(typed.Value{.f64 = 4.1}, try validator.validateValue(.{.f64 = 4.1}, &context));
		try t.expectEqual(true, context.isValid());
	}

	{
		t.reset(&context);
		try t.expectEqual(nullValue, try validator.validateValue(.{.i64 = 99}, &context));
		try t.expectInvalid(.{.code = codes.TYPE_FLOAT}, context);
	}
}

test "float: not strict" {
	var context = t.context();
	defer context.deinit(t.allocator);

	var builder = t.builder();
	defer builder.deinit(t.allocator);

	const validator = builder.float(f64, .{});

	{
		try t.expectEqual(typed.Value{.f64 = 4.1}, try validator.validateValue(.{.f64 = 4.1}, &context));
		try t.expectEqual(true, context.isValid());
	}

	{
		t.reset(&context);
		try t.expectEqual(typed.Value{.f64 = 99}, try validator.validateValue(.{.i64 = 99}, &context));
		try t.expectEqual(true, context.isValid());
	}
}

test "float: min" {
	var context = t.context();
	defer context.deinit(t.allocator);

	var builder = t.builder();
	defer builder.deinit(t.allocator);

	const validator = builder.float(f64, .{.min = 4.2});
	{
		try t.expectEqual(nullValue, try validator.validateValue(.{.f64 = 4.1}, &context));
		try t.expectInvalid(.{.code = codes.FLOAT_MIN, .data = .{.min = 4.2}, .err = "cannot be less than 4.2"}, context);
	}

	{
		t.reset(&context);
		try t.expectEqual(typed.Value{.f64 = 4.2}, try validator.validateValue(.{.f64 = 4.2}, &context));
		try t.expectEqual(true, context.isValid());
	}

	{
		t.reset(&context);
		try t.expectEqual(typed.Value{.f64 = 293.2}, try validator.validateValue(.{.f64 = 293.2}, &context));
		try t.expectEqual(true, context.isValid());
	}
}

test "float: max" {
	var context = t.context();
	defer context.deinit(t.allocator);

	var builder = t.builder();
	defer builder.deinit(t.allocator);

	const validator = builder.float(f64, .{.max = 4.1});

	{
		try t.expectEqual(nullValue, (try validator.validateValue(.{.f64 = 4.2}, &context)));
		try t.expectInvalid(.{.code = codes.FLOAT_MAX, .data = .{.max = 4.1}}, context);
	}

	{
		t.reset(&context);
		try t.expectEqual(typed.Value{.f64 = 4.1}, (try validator.validateValue(.{.f64 = 4.1}, &context)));
		try t.expectEqual(true, context.isValid());
	}

	{
		t.reset(&context);
		try t.expectEqual(typed.Value{.f64 = -33.2}, (try validator.validateValue(.{.f64 = -33.2}, &context)));
		try t.expectEqual(true, context.isValid());
	}
}

test "float: function" {
	var context = try Context(f64).init(t.allocator, .{.max_errors = 2, .max_nesting = 1}, 101);
	defer context.deinit(t.allocator);

	const builder = try Builder(f64).init(t.allocator);
	defer builder.deinit(t.allocator);

	const validator = builder.float(f64, .{.function = testFloatValidator});

	{
		try t.expectEqual(nullValue, try validator.validateValue(.{.f64 = 99.1}, &context));
		try t.expectEqual(true, context.isValid());
	}

	{
		try t.expectEqual(@as(f64, -9999.88), (try validator.validateValue(null, &context)).f64);
		try t.expectEqual(true, context.isValid());
	}

	{
		t.reset(&context);
		try t.expectEqual(@as(f64, -38291.2), (try validator.validateValue(.{.f64 = 2.1}, &context)).f64);
		try t.expectEqual(true, context.isValid());
	}

	{
		t.reset(&context);
		try t.expectEqual(nullValue, try validator.validateValue(.{.f64 = 3.2}, &context));
		try t.expectInvalid(.{.code = 997, .err = "float validation error"}, context);
	}
}

test "float: parse" {
	var context = t.context();
	defer context.deinit(t.allocator);

	var builder = t.builder();
	defer builder.deinit(t.allocator);

	const validator = builder.float(f64, .{.max = 4.2, .parse = true});

	{
		// still works fine with correct type
		try t.expectEqual(nullValue, try validator.validateValue(.{.f64 = 4.3}, &context));
		try t.expectInvalid(.{.code = codes.FLOAT_MAX, .data = .{.max = 4.2}}, context);
	}

	{
		// parses a string and applies the validation on the parsed value
		t.reset(&context);
		try t.expectEqual(nullValue, try validator.validateValue(.{.string = "4.3"}, &context));
		try t.expectInvalid(.{.code = codes.FLOAT_MAX, .data = .{.max = 4.2}}, context);
	}

	{
		// parses a string and returns the typed value
		t.reset(&context);
		try t.expectEqual(@as(f64, 4.1), (try validator.validateValue(.{.string = "4.1"}, &context)).f64);
		try t.expectEqual(true, context.isValid());
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

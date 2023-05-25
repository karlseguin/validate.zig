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
		min: T,
		max: T,
		parse: bool,
		strict: bool,
		default: ?T,
		min_invalid: v.Invalid,
		max_invalid: v.Invalid,
		function: ?*const fn(value: ?T, context: *Context(S)) anyerror!?T,

		const T_MAX = std.math.floatMax(T);
		// floatMin returns the smallest decimal, something like 0.00006103515625 for an f32
		// (clearly not the minimal float!). Very inconsistent. I believe -T_MAX is correct.
		const T_MIN = -T_MAX;

		const Self = @This();

		const InvalidType = enum {
			none,
			min,
			max,
			type,
		};

		pub const Config = struct {
			min: ?T = null,
			max: ?T = null,
			default: ?T = null,
			parse: bool = false,
			strict: bool = false,
			required: bool = false,
			function: ?*const fn(value: ?T, context: *Context(S)) anyerror!?T = null,
		};

		pub fn init(allocator: Allocator, config: Config) !Self {
			const min = config.min orelse T_MIN;

			const min_invalid = v.Invalid{
				.code = codes.FLOAT_MIN,
				.data = try DataBuilder.init(allocator).put("min", min).done(),
				.err = try std.fmt.allocPrint(allocator, "cannot be less than {d}", .{min}),
			};

			const max = config.max orelse T_MAX;
			const max_invalid = v.Invalid{
				.code = codes.FLOAT_MAX,
				.data = try DataBuilder.init(allocator).put("max", max).done(),
				.err = try std.fmt.allocPrint(allocator, "cannot be greater than {d}", .{max}),
			};

			return .{
				.min = min,
				.max = max,
				.parse = config.parse,
				.strict = config.strict,
				.default = config.default,
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
				var invalid_type = InvalidType.none;
				switch (untyped_value) {
					.f64 => |n| {
						if (n < T_MIN) { invalid_type = .min;
						} else if (n > T_MAX) { invalid_type = .max;
						} else float_value = @floatCast(T, n);
					},
					.f32 => |n| {
						if (n < T_MIN) { invalid_type = .min;
						} else if (n > T_MAX) { invalid_type = .max;
						} else float_value = @floatCast(T, n);
					},
					.string => |s| blk: {
						if (self.parse) {
							float_value = std.fmt.parseFloat(T, s) catch {
								invalid_type = .type;
								break :blk;
							};
						} else {
							invalid_type = .type;
						}
					},
					else => {
						if (!self.strict) {
							switch (untyped_value) {
								.i8 => |n| float_value = @intToFloat(T, n),
								.i16 => |n| float_value = @intToFloat(T, n),
								.i32 => |n| float_value = @intToFloat(T, n),
								.i64 => |n| float_value = @intToFloat(T, n),
								.i128 => |n| float_value = @intToFloat(T, n),
								.u8 => |n| float_value = @intToFloat(T, n),
								.u16 => |n| float_value = @intToFloat(T, n),
								.u32 => |n| float_value = @intToFloat(T, n),
								.u64 => |n| float_value = @intToFloat(T, n),
								.u128 => |n|float_value = @intToFloat(T, n),
								else => invalid_type = .type,
							}
						} else {
							invalid_type = .type;
						}
					}
				}

				switch (invalid_type) {
					.none => {},
					.min => {
						try context.add(self.min_invalid);
						return .{.null = {}};
					},
					.max => {
						try context.add(self.max_invalid);
						return .{.null = {}};
					},
					.type => {
						try context.add(INVALID_TYPE);
						return .{.null = {}};
					},
				}
			}

			if (try self.validate(float_value, context)) |value| {
				return typed.new(value);
			}
			return .{.null = {}};
		}

		pub fn validateString(self: *const Self, input: ?[]const u8, context: *Context(S)) !?T {
			var float_value: ?T = null;
			if (input) |string_value| {
				float_value = std.fmt.parseFloat(T, string_value,) catch {
					try context.add(INVALID_TYPE);
					return null;
				};
			}
			return self.validate(float_value, context);
		}

		pub fn validate(self: *const Self, optional_value: ?T, context: *Context(S)) !?T {
			const value = optional_value orelse {
				if (self.required) {
					try context.add(v.required);
					return null;
				}
				return self.executeFunction(null, context);
			};

			if (value < self.min) {
				try context.add(self.min_invalid);
				return null;
			}

			if (value > self.max) {
				try context.add(self.max_invalid);
				return null;
			}

			return self.executeFunction(value, context);
		}

		fn executeFunction(self: *const Self, value: ?T, context: *Context(S)) !?T {
			if (self.function) |f| {
				return (try f(value, context)) orelse self.default;
			}
			return value orelse self.default;
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

	const not_required = builder.float(f64, .{.required = false});
	const required = not_required.setRequired(true, &builder);
	const not_required_default = builder.float(f64, .{.required = false, .default = 123.45});

	{
		try t.expectEqual(nullValue, try required.validateValue(null, &context));
		try t.expectInvalid(.{.code = codes.REQUIRED}, context);
	}

	{
		t.reset(&context);
		try t.expectEqual(nullValue, try not_required.validateValue(null, &context));
		try t.expectEqual(true, context.isValid());
	}

	{
		t.reset(&context);
		try t.expectEqual(@as(f64, 123.45), (try not_required_default.validateValue(null, &context)).f64);
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
		std.debug.print("HERE\n", .{});
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

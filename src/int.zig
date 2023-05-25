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
	.code = codes.TYPE_INT,
	.err = "must be an int",
};

pub fn Int(comptime T: type, comptime S: type) type {
	if (@typeInfo(T) != .Int) {
		@compileError(@typeName(T) ++ " is not an integer");
	}
	if (@typeInfo(T).Int.bits > 128) {
		@compileError("int validator does not support integers wider than 128 bits");
	}

	return struct {
		required: bool,
		min: T, // there is always a min/max, either explicitly configured, or inferred from the type
		max: T,
		parse: bool,
		default: ?T,
		min_invalid: v.Invalid,
		max_invalid: v.Invalid,
		function: ?*const fn(value: ?T, context: *Context(S)) anyerror!?T,

		const T_MIN = std.math.minInt(T);
		const T_MAX = std.math.maxInt(T);

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
			required: bool = false,
			function: ?*const fn(value: ?T, context: *Context(S)) anyerror!?T = null,
		};

		pub fn init(allocator: Allocator, config: Config) !Self {
			const min = config.min orelse T_MIN;
			const min_invalid = v.Invalid{
				.code = codes.INT_MIN,
				.data = try DataBuilder.init(allocator).put("min", min).done(),
				.err = try std.fmt.allocPrint(allocator, "cannot be less than {d}", .{min}),
			};

			const max = config.max orelse T_MAX;
			const max_invalid = v.Invalid{
				.code = codes.INT_MAX,
				.data = try DataBuilder.init(allocator).put("max", max).done(),
				.err = try std.fmt.allocPrint(allocator, "cannot be greater than {d}", .{max}),
			};

			return .{
				.min = min,
				.max = max,
				.parse = config.parse,
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

		pub fn trySetRequired(self: *Self, req: bool, builder: *Builder(S)) !*Int(T, S) {
			var clone = try builder.allocator.create(Int(T, S));
			clone.* = self.*;
			clone.required = req;
			return clone;
		}
		pub fn setRequired(self: *Self, req: bool, builder: *Builder(S)) *Int(T, S) {
			return self.trySetRequired(req, builder) catch unreachable;
		}

		// part of the Validator interface, but noop for ints
		pub fn nestField(_: *Self, _: Allocator, _: *v.Field) !void {}

		pub fn validateValue(self: *const Self, input: ?typed.Value, context: *Context(S)) !typed.Value {
			var int_value: ?T = null;
			if (input) |untyped_value| {
				var invalid_type = InvalidType.none;
				switch (untyped_value) {
					.i64 => |n| {
						if (n < T_MIN) { invalid_type = .min;
						} else if (n > T_MAX) { invalid_type = .max;
						} else int_value = @intCast(T, n);
					},
					.i32 => |n| {
						if (n < T_MIN) { invalid_type = .min;
						} else if (n > T_MAX) { invalid_type = .max;
						} else int_value = @intCast(T, n);
					},
					.i16 => |n| {
						if (n < T_MIN) { invalid_type = .min;
						} else if (n > T_MAX) { invalid_type = .max;
						} else int_value = @intCast(T, n);
					},
					.i8 => |n| {
						if (n < T_MIN) { invalid_type = .min;
						} else if (n > T_MAX) { invalid_type = .max;
						} else int_value = @intCast(T, n);
					},
					.u64 => |n| {
						if (n < T_MIN) { invalid_type = .min;
						} else if (n > T_MAX) { invalid_type = .max;
						} else int_value = @intCast(T, n);
					},
					.u32 => |n| {
						if (n < T_MIN) { invalid_type = .min;
						} else if (n > T_MAX) { invalid_type = .max;
						} else int_value = @intCast(T, n);
					},
					.u16 => |n| {
						if (n < T_MIN) { invalid_type = .min;
						} else if (n > T_MAX) { invalid_type = .max;
						} else int_value = @intCast(T, n);
					},
					.u8 => |n| {
						if (n < T_MIN) { invalid_type = .min;
						} else if (n > T_MAX) { invalid_type = .max;
						} else int_value = @intCast(T, n);
					},
					.i128 => |n| {
						if (n < T_MIN) { invalid_type = .min;
						} else if (n > T_MAX) { invalid_type = .max;
						} else int_value = @intCast(T, n);
					},
					.u128 => |n| {
						if (n < T_MIN) { invalid_type = .min;
						} else if (n > T_MAX) { invalid_type = .max;
						} else int_value = @intCast(T, n);
					},
					.string => |s| blk: {
						if (self.parse) {
							int_value = std.fmt.parseInt(T, s, 10) catch {
								invalid_type = .type;
								break :blk;
							};
						} else {
							invalid_type = .type;
						}
					},
					else => invalid_type = .type,
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

			if (try self.validate(int_value, context)) |value| {
				return typed.new(value);
			}
			return .{.null = {}};
		}

		pub fn validateString(self: *const Self, input: ?[]const u8, context: *Context(S)) !?T {
			var int_value: ?T = null;
			if (input) |string_value| {
				int_value = std.fmt.parseInt(T, string_value, 10) catch {
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
test "int: required" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 1}, {});
	defer context.deinit(t.allocator);

	var builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const not_required = builder.int(i64, .{.required = false});
	const required = not_required.setRequired(true, &builder);
	const not_required_default = builder.int(i64, .{.required = false, .default = 991913});

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
		try t.expectEqual(@as(i64, 991913), (try not_required_default.validateValue(null, &context)).i64);
		try t.expectEqual(true, context.isValid());
	}

	{
		// test required = false when configured directly (not via setRequired)
		t.reset(&context);
		const validator = builder.int(i64, .{.required = false});
		try t.expectEqual(nullValue, try validator.validateValue(null, &context));
		try t.expectEqual(true, context.isValid());
	}
}

test "int: type" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 1}, {});
	defer context.deinit(t.allocator);

	const builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const validator = builder.int(i64, .{});
	try t.expectEqual(nullValue, try validator.validateValue(.{.string = "NOPE"}, &context));
	try t.expectInvalid(.{.code = codes.TYPE_INT}, context);
}

test "int: min" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 1}, {});
	defer context.deinit(t.allocator);

	const builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const validator = builder.int(i64, .{.min = 4});
	{
		try t.expectEqual(nullValue, try validator.validateValue(.{.i64 = 3}, &context));
		try t.expectInvalid(.{.code = codes.INT_MIN, .data = .{.min = 4}}, context);
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

	const validator = builder.int(i64, .{.max = 4});

	{
		try t.expectEqual(nullValue, try validator.validateValue(.{.i64 = 5}, &context));
		try t.expectInvalid(.{.code = codes.INT_MAX, .data = .{.max = 4}}, context);
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

	const validator = builder.int(i64, .{.function = testIntValidator});

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

	const validator = builder.int(i64, .{.max = 4, .parse = true});

	{
		// still works fine with correct type
		try t.expectEqual(nullValue, try validator.validateValue(.{.i64 = 5}, &context));
		try t.expectInvalid(.{.code = codes.INT_MAX, .data = .{.max = 4}}, context);
	}

	{
		// parses a string and applies the validation on the parsed value
		t.reset(&context);
		try t.expectEqual(nullValue, try validator.validateValue(.{.string = "5"}, &context));
		try t.expectInvalid(.{.code = codes.INT_MAX, .data = .{.max = 4}}, context);
	}

	{
		// parses a string and returns the typed value
		t.reset(&context);
		try t.expectEqual(@as(i64, 3), (try validator.validateValue(.{.string = "3"}, &context)).i64);
		try t.expectEqual(true, context.isValid());
	}
}

test "int: implicit min and max" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 1}, {});
	defer context.deinit(t.allocator);

	const builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);
	const utypes = [_]type{u8, u16, u32};
	inline for (utypes) |utype| {
		t.reset(&context);
		const max_int = std.math.maxInt(utype);
		const validator = builder.int(utype, .{});
		try t.expectEqual(nullValue, try validator.validateValue(.{.u64 = max_int + 1}, &context));
		try t.expectInvalid(.{.code = codes.INT_MAX, .data = .{.max = max_int}}, context);
	}

	const itypes = [_]type{i8, i16, i32};
	inline for (itypes) |itype| {
		t.reset(&context);
		const min_int = std.math.minInt(itype);
		const max_int = std.math.maxInt(itype);
		const validator = builder.int(itype, .{});
		try t.expectEqual(nullValue, try validator.validateValue(.{.i64 = min_int - 1}, &context));
		try t.expectInvalid(.{.code = codes.INT_MIN, .data = .{.min = min_int}}, context);

		try t.expectEqual(nullValue, try validator.validateValue(.{.i64 = max_int + 1}, &context));
		try t.expectInvalid(.{.code = codes.INT_MAX, .data = .{.max = max_int}}, context);
	}
}

test "int: implicit type cast" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 1}, {});
	defer context.deinit(t.allocator);

	const builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);
	const utypes = [_]type{u8, u16, u32};
	inline for (utypes) |utype| {
		const max_int = std.math.maxInt(utype);
		const validator = builder.int(utype, .{});

		try t.expectEqual(@as(utype, max_int), (try validator.validateValue(.{.u64 = max_int}, &context)).get(utype).?);
		try t.expectEqual(true, context.isValid());

		try t.expectEqual(@as(utype, 0), (try validator.validateValue(.{.u64 = 0}, &context)).get(utype).?);
		try t.expectEqual(true, context.isValid());
	}

	const itypes = [_]type{i8, i16, i32};
	inline for (itypes) |itype| {
		const min_int = std.math.minInt(itype);
		const max_int = std.math.maxInt(itype);
		const validator = builder.int(itype, .{});

		try t.expectEqual(@as(itype, max_int), (try validator.validateValue(.{.i64 = max_int}, &context)).get(itype).?);
		try t.expectEqual(true, context.isValid());

		try t.expectEqual(@as(itype, min_int), (try validator.validateValue(.{.i64 = min_int}, &context)).get(itype).?);
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

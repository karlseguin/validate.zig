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
	.code = codes.TYPE_TIME,
	.err = "must be a time value",
};

pub fn Time(comptime S: type) type {
	return struct {
		required: bool,
		min: ?typed.Time,
		max: ?typed.Time,
		parse: bool,
		default: ?typed.Time,
		min_invalid: ?v.Invalid,
		max_invalid: ?v.Invalid,
		function: ?*const fn(value: ?typed.Time, context: *Context(S)) anyerror!?typed.Time,

		const Self = @This();

		pub const Config = struct {
			min: ?typed.Time = null,
			max: ?typed.Time = null,
			parse: bool = false,
			required: bool = false,
			default: ?typed.Time = null,
			function: ?*const fn(value: ?typed.Time, context: *Context(S)) anyerror!?typed.Time = null,
		};

		pub fn init(allocator: Allocator, config: Config) !Self {
			var min_invalid: ?v.Invalid = null;
			if (config.min) |m| {
				min_invalid = v.Invalid{
					.code = codes.TIME_MIN,
					.data = try DataBuilder.init(allocator).put("min", m).done(),
					.err = try std.fmt.allocPrint(allocator, "cannot be before {d}", .{m}),
				};
			}

			var max_invalid: ?v.Invalid = null;
			if (config.max) |m| {
				max_invalid = v.Invalid{
					.code = codes.TIME_MAX,
					.data = try DataBuilder.init(allocator).put("max", m).done(),
					.err = try std.fmt.allocPrint(allocator, "cannot be after {d}", .{m}),
				};
			}

			return .{
				.min = config.min,
				.max = config.max,
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

		pub fn trySetRequired(self: *Self, req: bool, builder: *Builder(S)) !*Time(S) {
			var clone = try builder.allocator.create(Time(S));
			clone.* = self.*;
			clone.required = req;
			return clone;
		}
		pub fn setRequired(self: *Self, req: bool, builder: *Builder(S)) *Time(S) {
			return self.trySetRequired(req, builder) catch unreachable;
		}

		// part of the Validator interface, but noop for dates
		pub fn nestField(_: *Self, _: Allocator, _: *v.Field) !void {}

		pub fn validateValue(self: *const Self, input: ?typed.Value, context: *Context(S)) !typed.Value {
			var time_value: ?typed.Time = null;
			if (input) |untyped_value| {
				var valid = false;
				switch (untyped_value) {
					.time => |n| {
						valid = true;
						time_value = n;
					},
					.string => |s| blk: {
						if (self.parse) {
							time_value = typed.Time.parse(s, .rfc3339) catch break :blk;
							valid = true;
						}
					},
					else => {}
				}

				if (!valid) {
					try context.add(INVALID_TYPE);
					return .{.null = {}};
				}
			}

			if (try self.validate(time_value, context)) |value| {
				return typed.new(context.allocator, value);
			}
			return .{.null = {}};
		}

		pub fn validateString(self: *const Self, input: ?[]const u8, context: *Context(S)) !?typed.Time {
			var time_value: ?typed.Time = null;
			if (input) |string_value| {
				time_value = typed.Time.parse(string_value) catch {
					try context.add(INVALID_TYPE);
					return null;
				};
			}
			return self.validate(time_value, context);
		}

		pub fn validate(self: *const Self, optional_value: ?typed.Time, context: *Context(S)) !?typed.Time {
			const value = optional_value orelse {
				if (self.required) {
					try context.add(v.required);
					return null;
				}
				return self.executeFunction(null, context);
			};

			if (self.min) |m| {
				std.debug.assert(self.min_invalid != null);
				if (value.order(m) == .lt) {
					try context.add(self.min_invalid.?);
					return null;
				}
			}

			if (self.max) |m| {
				std.debug.assert(self.max_invalid != null);
				if (value.order(m) == .gt) {
					try context.add(self.max_invalid.?);
					return null;
				}
			}

			return self.executeFunction(value, context);
		}

		fn executeFunction(self: *const Self, value: ?typed.Time, context: *Context(S)) !?typed.Time {
			if (self.function) |f| {
				return (try f(value, context)) orelse self.default;
			}
			return value orelse self.default;
		}
	};
}

const t = @import("t.zig");
const nullValue = typed.Value{.null = {}};
test "time: required" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 1}, {});
	defer context.deinit(t.allocator);

	var builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const default = try typed.Time.parse("08:27:33.923911", .rfc3339);
	const not_required = builder.time(.{.required = false});
	const required = not_required.setRequired(true, &builder);
	const not_required_default = builder.time(.{.required = false, .default = default });

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
		try t.expectEqual(default, (try not_required_default.validateValue(null, &context)).time);
		try t.expectEqual(true, context.isValid());
	}

	{
		// test required = false when configured directly (not via setRequired)
		t.reset(&context);
		const validator = builder.time(.{.required = false});
		try t.expectEqual(nullValue, try validator.validateValue(null, &context));
		try t.expectEqual(true, context.isValid());
	}
}

test "time: type" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 1}, {});
	defer context.deinit(t.allocator);

	const builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const validator = builder.time(.{});
	try t.expectEqual(nullValue, try validator.validateValue(.{.string = "NOPE"}, &context));
	try t.expectInvalid(.{.code = codes.TYPE_TIME}, context);
}

test "time: min" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 1}, {});
	defer context.deinit(t.allocator);

	const builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const validator = builder.time(.{.min = try typed.Time.parse("10:05:10", .rfc3339)});
	{
		try t.expectEqual(nullValue, try validator.validateValue(.{.time = try typed.Time.parse("10:05:09", .rfc3339)}, &context));
		try t.expectInvalid(.{.code = codes.TIME_MIN, .data = .{.min = "10:05:10"}}, context);
	}

	{
		t.reset(&context);
		const d = try typed.Time.parse("10:05:10", .rfc3339);
		try t.expectEqual(typed.Value{.time = d}, try validator.validateValue(.{.time = d}, &context));
		try t.expectEqual(true, context.isValid());
	}

	{
		t.reset(&context);
		const d = try typed.Time.parse("10:05:11", .rfc3339);
		try t.expectEqual(typed.Value{.time = d}, try validator.validateValue(.{.time = d}, &context));
		try t.expectEqual(true, context.isValid());
	}
}

test "time: max" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 1}, {});
	defer context.deinit(t.allocator);

	const builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const validator = builder.time(.{.max = try typed.Time.parse("10:05:10", .rfc3339)});

	{
		try t.expectEqual(nullValue, try validator.validateValue(.{.time = try typed.Time.parse("10:05:11", .rfc3339)}, &context));
		try t.expectInvalid(.{.code = codes.TIME_MAX, .data = .{.max = "10:05:10"}}, context);
	}

	{
		t.reset(&context);
		const d = try typed.Time.parse("10:05:10", .rfc3339);
		try t.expectEqual(typed.Value{.time = d}, try validator.validateValue(.{.time = d}, &context));
		try t.expectEqual(true, context.isValid());
	}

	{
		t.reset(&context);
		const d = try typed.Time.parse("10:05:09", .rfc3339);
		try t.expectEqual(typed.Value{.time = d}, try validator.validateValue(.{.time = d}, &context));
		try t.expectEqual(true, context.isValid());
	}
}


test "time: parse" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 1}, {});
	defer context.deinit(t.allocator);

	const builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const validator = builder.time(.{.max = try typed.Time.parse("10:05:10", .rfc3339), .parse = true});

	{
		// still works fine with correct type
		try t.expectEqual(nullValue, try validator.validateValue(.{.time = try typed.Time.parse("10:05:11", .rfc3339)}, &context));
		try t.expectInvalid(.{.code = codes.TIME_MAX, .data = .{.max = "10:05:10"}}, context);
	}

	{
		// parses a string and applies the validation on the parsed value
		t.reset(&context);
		try t.expectEqual(nullValue, try validator.validateValue(.{.string = "10:05:11"}, &context));
		try t.expectInvalid(.{.code = codes.TIME_MAX, .data = .{.max = "10:05:10"}}, context);
	}

	{
		// parses a string and returns the typed value
		t.reset(&context);
		try t.expectEqual(try typed.Time.parse("10:05:10", .rfc3339), (try validator.validateValue(.{.string = "10:05:10"}, &context)).time);
		try t.expectEqual(true, context.isValid());
	}
}

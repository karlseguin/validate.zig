const std = @import("std");
const json = std.json;

const t = @import("t.zig");

const v = @import("validate.zig");
const codes = @import("codes.zig");
const Builder = @import("builder.zig").Builder;
const Context = @import("context.zig").Context;
const Validator = @import("validator.zig").Validator;

const Allocator = std.mem.Allocator;


pub fn Any(comptime S: type) type {
	return struct {
		required: bool,
		function: ?*const fn(value: ?json.Value, context: *Context(S)) anyerror!?json.Value,

		const Self = @This();

		pub const Config = struct {
			required: bool = false,
			function: ?*const fn(value: ?json.Value, context: *Context(S)) anyerror!?json.Value = null,
		};

		pub fn init(_: Allocator, config: Config) !Self {
			return .{
				.required = config.required,
				.function = config.function,
			};
		}

		pub fn validator(self: *Self) Validator(S) {
			return Validator(S).init(self);
		}

		pub fn trySetRequired(self: *Self, req: bool, builder: *Builder(S)) !*Any(S) {
			var clone = try builder.allocator.create(Any(S));
			clone.* = self.*;
			clone.required = req;
			return clone;
		}
		pub fn setRequired(self: *Self, req: bool, builder: *Builder(S)) *Any(S) {
			return self.trySetRequired(req, builder) catch unreachable;
		}

		// part of the Validator interface, but noop for any
		pub fn nestField(_: *Self, _: Allocator, _: *v.Field) !void {}

		pub fn validateJsonValue(self: *const Self, optional_value: ?json.Value, context: *Context(S)) !?json.Value {
			const untyped_value = optional_value orelse {
				if (self.required) {
					try context.add(v.required);
				}
				return self.executeFunction(null, context);
			};
			return self.executeFunction(untyped_value, context);
		}

		fn executeFunction(self: *const Self, value: ?json.Value, context: *Context(S)) !?json.Value {
			if (self.function) |f| {
				return f(value, context);
			}
			return null;
		}
	};
}

const nullJson = @as(?json.Value, null);
test "any: required" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 1}, {});
	defer context.deinit(t.allocator);

	var builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const notRequired = builder.any(.{.required = false, });
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
		const validator = builder.any(.{.required = false});
		try t.expectEqual(nullJson, try validator.validateJsonValue(null, &context));
		try t.expectEqual(true, context.isValid());
	}
}

test "any: function" {
	var context = try Context(i64).init(t.allocator, .{.max_errors = 2, .max_nesting = 1}, 22);
	defer context.deinit(t.allocator);

	const builder = try Builder(i64).init(t.allocator);
	defer builder.deinit(t.allocator);

	const validator = builder.any(.{.function = testAnyValidator});

	{
		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.Integer = 1}, &context));
		try t.expectEqual(true, context.isValid());
	}

	{
		try t.expectEqual(@as(f64, 12.3), (try validator.validateJsonValue(.{.Integer = 32}, &context)).?.Float);
		try t.expectEqual(true, context.isValid());
	}

	{
		t.reset(&context);
		try t.expectEqual(@as(i64, 9991), (try validator.validateJsonValue(null, &context)).?.Integer);
		try t.expectEqual(true, context.isValid());
	}

	{
		t.reset(&context);
		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.Integer = 3}, &context));
		try t.expectInvalid(.{.code = 28, .err = "any validation error"}, context);
	}
}

fn testAnyValidator(value: ?json.Value, context: *Context(i64)) !?json.Value {
	std.debug.assert(context.state == 22);

	const n = value orelse return json.Value{.Integer = 9991};

	if (n.Integer == 32) {
		return .{.Float = 12.3};
	}
	if (n.Integer == 1) {
		return null;
	}
	if (n.Integer == 3) {
		try context.add(v.Invalid{
			.code = 28,
			.err = "any validation error",
		});
		return null;
	}
	unreachable;
}

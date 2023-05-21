const std = @import("std");
const typed = @import("typed");
const v = @import("validate.zig");

const codes = v.codes;
const Builder = v.Builder;
const Context = v.Context;
const Validator = v.Validator;

const Allocator = std.mem.Allocator;

pub fn Any(comptime S: type) type {
	return struct {
		required: bool,
		function: ?*const fn(value: ?typed.Value, context: *Context(S)) anyerror!?typed.Value,

		const Self = @This();

		pub const Config = struct {
			required: bool = false,
			function: ?*const fn(value: ?typed.Value, context: *Context(S)) anyerror!?typed.Value = null,
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

		pub fn validateValue(self: *const Self, optional_value: ?typed.Value, context: *Context(S)) !typed.Value {
			if (try self.validate(optional_value, context)) |value| {
				return value;
			}
			return .{.null = {}};
		}

		pub fn validate(self: *const Self, optional_value: ?typed.Value, context: *Context(S)) !?typed.Value {
			const untyped_value = optional_value orelse {
				if (self.required) {
					try context.add(v.required);
					return null;
				}
				return self.executeFunction(null, context);
			};
			return self.executeFunction(untyped_value, context);
		}

		fn executeFunction(self: *const Self, value: ?typed.Value, context: *Context(S)) !?typed.Value {
			if (self.function) |f| {
				return f(value, context);
			}
			return null;
		}
	};
}

const t = @import("t.zig");
const nullValue = typed.Value{.null = {}};
test "any: required" {
	var context = t.context();
	defer context.deinit(t.allocator);

	var builder = t.builder();
	defer builder.deinit(t.allocator);

	const notRequired = builder.any(.{.required = false, });
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
		const validator = builder.any(.{.required = false});
		try t.expectEqual(nullValue, try validator.validateValue(null, &context));
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
		try t.expectEqual(nullValue, try validator.validateValue(.{.i64 = 1}, &context));
		try t.expectEqual(true, context.isValid());
	}

	{
		try t.expectEqual(@as(f32, 12.3), (try validator.validateValue(.{.i64 = 32}, &context)).f32);
		try t.expectEqual(true, context.isValid());
	}

	{
		t.reset(&context);
		try t.expectEqual(@as(i64, 9991), (try validator.validateValue(null, &context)).i64);
		try t.expectEqual(true, context.isValid());
	}

	{
		t.reset(&context);
		try t.expectEqual(nullValue, try validator.validateValue(.{.i64 = 3}, &context));
		try t.expectInvalid(.{.code = 28, .err = "any validation error"}, context);
	}
}

fn testAnyValidator(value: ?typed.Value, context: *Context(i64)) !?typed.Value {
	std.debug.assert(context.state == 22);

	const n = value orelse return typed.Value{.i64 = 9991};

	if (n.i64 == 32) {
		return .{.f32 = 12.3};
	}
	if (n.i64 == 1) {
		return null;
	}
	if (n.i64 == 3) {
		try context.add(v.Invalid{
			.code = 28,
			.err = "any validation error",
		});
		return null;
	}
	unreachable;
}

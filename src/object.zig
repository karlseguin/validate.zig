const std = @import("std");
const json = std.json;

const t = @import("t.zig");

const v = @import("validate.zig");
const codes = @import("codes.zig");
const Context = @import("context.zig").Context;
const Validator = @import("validator.zig").Validator;

const INVALID_TYPE = v.Invalid{
	.code = codes.OBJECT_TYPE,
	.@"error" = "must be an object",
};

pub fn FieldS(comptime S: type) type {
	return struct {
		name: []const u8,
		validator: Validator(S),
	};
}

pub fn ObjectConfig(comptime S: type) type {
	return struct {
		required: bool = false,
		fields: ?[]const FieldS(S) = null,
	};
}

pub fn Object(comptime S: type) type {
	return struct {
		required: bool,
		fields: ?[]const FieldS(S),

		const Self = @This();

		pub fn validator(self: *const Self) Validator(S) {
			return Validator(S).init(self);
		}

		pub fn validateJson(self: *const Self, optional_value: ?json.Value, context: *Context(S)) !void {
			const untyped_value = optional_value orelse {
				if (self.required) {
					return context.add(v.required);
				}
				return;
			};

			const value = switch (untyped_value) {
				.Object => |o| o,
				else => return context.add(INVALID_TYPE),
			};

			if (self.fields) |fields| {
				context.startObject();
				for (fields) |f| {
					const name = f.name;
					context.setField(name);
					try f.validator.validateJson(value.get(name), context);
				}
				context.endObject();
			}
		}
	};
}

pub fn objectS(comptime S: type, config: ObjectConfig(S)) Object(S) {
	return .{
		.fields = config.fields,
		.required = config.required,
	};
}

pub fn object(config: ObjectConfig(void)) Object(void) {
	return .{
		.fields = config.fields,
		.required = config.required,
	};
}

test "object: required" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_depth = 2}, {});
	defer context.deinit(t.allocator);

	try objectS(void, .{.required = true}).validateJson(null, &context);
	try t.expectInvalid(.{.code = codes.REQUIRED}, context);

	context.reset();
	try objectS(void, .{.required = false}).validateJson(null, &context);
	try t.expectEqual(true, context.isValid());
}

test "object: type" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_depth = 2}, {});
	defer context.deinit(t.allocator);

	try object(.{}).validateJson(.{.String = "Hi"}, &context);
	try t.expectInvalid(.{.code = codes.OBJECT_TYPE}, context);
}

test "object: field" {
	std.debug.print("HERE\n", .{});
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_depth = 2}, {});
	defer context.deinit(t.allocator);

	const nameValidator = v.string(.{.required = true, .min = 3});

	t.validate("{}", object(.{.fields = &[_]v.Field{
		v.field("name", nameValidator.validator()),
	}}), &context);

	try t.expectInvalid(.{.code = codes.REQUIRED, .field = "name"}, context);
}

test "object: nested" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_depth = 2}, {});
	defer context.deinit(t.allocator);

	const nameValidator = v.string(.{.required = true, .min = 3});
	const userValidator = object(.{
		.required = true,
		.fields = &[_]v.Field{
			v.field("name", nameValidator.validator()),
		}
	});

	const dataValidator = object(.{.fields = &[_]v.Field{
		v.field("user", userValidator.validator()),
	}});

	{
		t.validate("{}", dataValidator, &context);
		try t.expectInvalid(.{.code = codes.REQUIRED, .field = "user"}, context);
	}

	{
		context.reset();
		t.validate("{\"user\": 3}", dataValidator, &context);
		try t.expectInvalid(.{.code = codes.OBJECT_TYPE, .field = "user"}, context);
	}

	{
		context.reset();
		t.validate("{\"user\": {}}", dataValidator, &context);
		try t.expectInvalid(.{.code = codes.REQUIRED, .field = "user.name"}, context);
	}
}

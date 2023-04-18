const std = @import("std");
const json = std.json;

const t = @import("t.zig");

const v = @import("validate.zig");
const codes = @import("codes.zig");
const Typed = @import("typed.zig").Typed;
const Context = @import("context.zig").Context;
const Validator = @import("validator.zig").Validator;

const INVALID_TYPE = v.Invalid{
	.code = codes.OBJECT_TYPE,
	.err = "must be an object",
};

pub fn Field(comptime S: type) type {
	return struct {
		name: []const u8,
		validator: Validator(S),
	};
}

pub fn ObjectConfig(comptime S: type) type {
	return struct {
		required: bool = false,
		fields: ?[]const Field(S) = null,
	};
}

pub fn Object(comptime S: type) type {
	return struct {
		required: bool,
		fields: ?[]const Field(S),

		const Self = @This();

		pub fn validator(self: *const Self) Validator(S) {
			return Validator(S).init(self);
		}

		pub fn validateJson(self: Self, data: []const u8, context: *Context(S)) !?Typed {
			const allocator = context.allocator; // an arena allocator
			var parser = std.json.Parser.init(allocator, false);
			var tree = try parser.parse(data);

			if (try self.validateJsonValue(tree.root, context)) |value| {
				return .{.root = value.Object};
			}
			return null;
		}

		pub fn validateJsonValue(self: *const Self, optional_value: ?json.Value, context: *Context(S)) !?json.Value {
			const untyped_value = optional_value orelse {
				if (self.required) {
					try context.add(v.required);
				}
				return null;
			};

			var value = switch (untyped_value) {
				.Object => |o| o,
				else => {
					try context.add(INVALID_TYPE);
					return null;
				},
			};

			if (self.fields) |fields| {
				context.startObject();
				for (fields) |f| {
					const name = f.name;
					context.setField(name);
					if (value.getEntry(name)) |entry| {
						if (try f.validator.validateJsonValue(entry.value_ptr.*, context)) |new_field_value| {
							entry.value_ptr.* = new_field_value;
						}
					} else {
						if (try f.validator.validateJsonValue(null, context)) |new_field_value| {
							try value.put(name, new_field_value);
						}
					}
				}
				context.endObject();
			}

			return optional_value;
		}
	};
}

pub fn object(comptime S: type, config: ObjectConfig(S)) Object(S) {
	return .{
		.fields = config.fields,
		.required = config.required,
	};
}

const nullJson = @as(?json.Value, null);
test "object: required" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_depth = 2}, {});
	defer context.deinit(t.allocator);

	{
		try t.expectEqual(nullJson, try object(void, .{.required = true}).validateJsonValue(null, &context));
		try t.expectInvalid(.{.code = codes.REQUIRED}, context);
	}

	{
		context.reset();
		try t.expectEqual(nullJson, try object(void, .{.required = false}).validateJsonValue(null, &context));
		try t.expectEqual(true, context.isValid());
	}
}

test "object: type" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_depth = 2}, {});
	defer context.deinit(t.allocator);

	try t.expectEqual(nullJson, try object(void, .{}).validateJsonValue(.{.String = "Hi"}, &context));
	try t.expectInvalid(.{.code = codes.OBJECT_TYPE}, context);
}

test "object: field" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_depth = 2}, {});
	defer context.deinit(t.allocator);

	const nameValidator = try v.string(void, t.allocator, .{.required = true, .min = 3});
	defer nameValidator.deinit(t.allocator);

	const objectValidator = object(void, .{.fields = &[_]v.Field(void){
		v.field(void, "name", nameValidator.validator()),
	}});

	_ = try objectValidator.validateJson("{}", &context);

	try t.expectInvalid(.{.code = codes.REQUIRED, .field = "name"}, context);
}

test "object: nested" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_depth = 2}, {});
	defer context.deinit(t.allocator);

	const nameValidator = try v.string(void, t.allocator, .{.required = true, .min = 3});
	defer nameValidator.deinit(t.allocator);

	const userValidator = object(void, .{
		.required = true,
		.fields = &[_]v.Field(void){
			v.field(void, "name", nameValidator.validator()),
		}
	});

	const dataValidator = object(void, .{.fields = &[_]v.Field(void){
		v.field(void, "user", userValidator.validator()),
	}});

	{
		_ = try dataValidator.validateJson("{}", &context);
		try t.expectInvalid(.{.code = codes.REQUIRED, .field = "user"}, context);
	}

	{
		context.reset();
		_ = try dataValidator.validateJson("{\"user\": 3}", &context);
		try t.expectInvalid(.{.code = codes.OBJECT_TYPE, .field = "user"}, context);
	}

	{
		context.reset();
		_ = try dataValidator.validateJson("{\"user\": {}}", &context);
		try t.expectInvalid(.{.code = codes.REQUIRED, .field = "user.name"}, context);
	}
}

test "object: change value" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_depth = 2}, {});
	defer context.deinit(t.allocator);

	const nameValidator = try v.string(void, t.allocator, .{.function = testChangeValue});
	defer nameValidator.deinit(t.allocator);

	const objectValidator = object(void, .{.fields = &[_]v.Field(void){
		v.field(void, "name", nameValidator.validator()),
	}});

	{
		const typed = try objectValidator.validateJson("{\"name\": \"normal\"}", &context) orelse unreachable;
		try t.expectEqual(true, context.isValid());
		try t.expectString("normal", typed.string("name").?);
	}

	{
		const typed = try objectValidator.validateJson("{\"name\": \"!\"}", &context) orelse unreachable;
		try t.expectEqual(true, context.isValid());
		try t.expectString("abc", typed.string("name").?);
	}
}

fn testChangeValue(value: []const u8, _: *Context(void)) !?[]const u8 {
	if (value[0] == '!') {
		return "abc";
	}
	return null;
}

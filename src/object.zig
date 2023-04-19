const std = @import("std");
const json = std.json;

const t = @import("t.zig");

const v = @import("validate.zig");
const codes = @import("codes.zig");
const Typed = @import("typed.zig").Typed;
const Builder = @import("builder.zig").Builder;
const Context = @import("context.zig").Context;
const Validator = @import("validator.zig").Validator;

const Allocator = std.mem.Allocator;

const INVALID_TYPE = v.Invalid{
	.code = codes.TYPE_OBJECT,
	.err = "must be an object",
};

pub fn Field(comptime S: type) type {
	return struct {
		name: []const u8,
		path: []const u8,
		validator: Validator(S),
	};
}

pub fn Object(comptime S: type) type {
	return struct {
		required: bool,
		fields: []const Field(S),

		const Self = @This();

		pub const Config = struct {
			required: bool = false,
		};

		pub fn init(allocator: Allocator, fields: []const Field(S), config: Config) !Self {
			for (@constCast(fields)) |*field| {
				try field.validator.nestField(allocator, field);
			}

			return .{
				.fields = fields,
				.required = config.required,
			};
		}

		pub fn validator(self: *const Self) Validator(S) {
			return Validator(S).init(self);
		}

		pub fn nestField(self: *const Self, allocator: Allocator, parent: *Field(S)) !void {
			const parent_path = parent.path;
			var fields = @constCast(self.fields);
			for (fields) |*field| {
				field.path = try std.fmt.allocPrint(allocator, "{s}.{s}", .{parent_path, field.path});
			}
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

			const fields = self.fields;
			for (fields) |f| {
				context.field = f;
				const name = f.name;
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

			return optional_value;
		}
	};
}

const nullJson = @as(?json.Value, null);
test "object: required" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 2}, {});
	defer context.deinit(t.allocator);

	const builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	{
		const validator = try builder.object(&.{}, .{.required = true});
		try t.expectEqual(nullJson, try validator.validateJsonValue(null, &context));
		try t.expectInvalid(.{.code = codes.REQUIRED}, context);
	}

	{
		context.reset();
		const validator = try builder.object(&.{}, .{.required = false});
		try t.expectEqual(nullJson, try validator.validateJsonValue(null, &context));
		try t.expectEqual(true, context.isValid());
	}
}

test "object: type" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 2}, {});
	defer context.deinit(t.allocator);

	const builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const validator = try builder.object(&.{}, .{});
	try t.expectEqual(nullJson, try validator.validateJsonValue(.{.String = "Hi"}, &context));
	try t.expectInvalid(.{.code = codes.TYPE_OBJECT}, context);
}

test "object: field" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 2}, {});
	defer context.deinit(t.allocator);

	const builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const nameValidator = try builder.string(.{.required = true, .min = 3});
	const objectValidator = try builder.object(&.{
		builder.field("name", &nameValidator),
	}, .{});

	_ = try objectValidator.validateJson("{}", &context);

	try t.expectInvalid(.{.code = codes.REQUIRED, .field = "name"}, context);
}

test "object: nested" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 10, .max_nesting = 2}, {});
	defer context.deinit(t.allocator);

	const builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const ageValidator = try builder.int(.{.required = true});
	const nameValidator = try builder.string(.{.required = true});
	const scoreValidator = try builder.float(.{.required = true});
	const enabledValidator = try builder.boolean(.{.required = true});
	const userValidator = try builder.object(&.{
		builder.field("age", &ageValidator),
		builder.field("name", &nameValidator),
		builder.field("score", &scoreValidator),
		builder.field("enabled", &enabledValidator),
	}, .{.required = true});
	const dataValidator = try builder.object(&.{builder.field("user", &userValidator)}, .{});

	{
		_ = try dataValidator.validateJson("{}", &context);
		try t.expectInvalid(.{.code = codes.REQUIRED, .field = "user"}, context);
	}

	{
		context.reset();
		_ = try dataValidator.validateJson("{\"user\": 3}", &context);
		try t.expectInvalid(.{.code = codes.TYPE_OBJECT, .field = "user"}, context);
	}

	{
		context.reset();
		_ = try dataValidator.validateJson("{\"user\": {}}", &context);
		try t.expectInvalid(.{.code = codes.REQUIRED, .field = "user.age"}, context);
		try t.expectInvalid(.{.code = codes.REQUIRED, .field = "user.name"}, context);
		try t.expectInvalid(.{.code = codes.REQUIRED, .field = "user.score"}, context);
		try t.expectInvalid(.{.code = codes.REQUIRED, .field = "user.enabled"}, context);
	}
}

test "object: change value" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 2}, {});
	defer context.deinit(t.allocator);

	const builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const nameValidator = try builder.string(.{.function = testChangeValue});
	const objectValidator = try builder.object(&.{
		builder.field("name", &nameValidator),
	}, .{});

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

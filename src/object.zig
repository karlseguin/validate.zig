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
		// This is the name of the field in the object. Used when we get the value
		// out of the map
		name: []const u8,

		// This is the full path of the field, including nesting. If we forget about
		// arrays for a second, field.name is always the suffix of field.path. So if
		// path == "result.user.id", then name == "id". This is what we use when
		// generating the field name in the error (we want to display the full path)
		path: []const u8,

		// The individual parts of the path. Necessary for arrays which require a
		// dynamically generated path. Essentially, you can imagine a path that's
		// like: "users.#.favorite.#" would have the following parts:
		// ["user", "", "favorite", ""]
		// Only needed when our field is nested under an array, null otherwise
		parts: ?[][]const u8 = null,

		validator: Validator(S),
	};
}

pub fn Object(comptime S: type) type {
	return struct {
		required: bool,
		fields: []Field(S),

		const Self = @This();

		pub const Config = struct {
			required: bool = false,
		};

		pub fn init(allocator: Allocator, fields: []const Field(S), config: Config) !Self {
			var owned = try allocator.alloc(Field(S), fields.len);
			for (@constCast(fields), 0..) |*field, i| {
				try field.validator.nestField(allocator, field);
				owned[i] = .{
					.name = field.name,
					.path = field.path,
					.parts = field.parts,
					.validator = field.validator,
				};
			}

			return .{
				.fields = owned,
				.required = config.required,
			};
		}

		pub fn validator(self: *const Self) Validator(S) {
			return Validator(S).init(self);
		}

		pub fn nestField(self: *const Self, allocator: Allocator, parent: *Field(S)) !void {
			const parent_path = parent.path;
			for (self.fields) |*field| {
				field.path = try std.fmt.allocPrint(allocator, "{s}.{s}", .{parent_path, field.path});
				if (field.parts) |parts| {
					const parent_parts = parent.parts.?;
					var new_parts = try allocator.alloc([]const u8, parent_parts.len + parts.len);
					for (parent_parts, 0..) |p, i| {
						new_parts[i] = p;
					}
					for (parts, 0..) |p, i| {
						new_parts[parent_parts.len + i] = p;
					}
					field.parts = new_parts;
				}
			}
		}

		pub fn validateJsonS(self: Self, data: []const u8, context: *Context(S)) !?Typed {
			const allocator = context.allocator; // an arena allocator
			var parser = std.json.Parser.init(allocator, false);
			var tree = try parser.parse(data);
			return self.validateJsonV(tree.root, context);
		}

		pub fn validateJsonV(self: Self, root: ?json.Value, context: *Context(S)) !?Typed {
			if (try self.validateJsonValue(root, context)) |value| {
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

			for (self.fields) |f| {
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

			return .{.Object = value};
		}
	};
}

const nullJson = @as(?json.Value, null);
test "object: required" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 2}, {});
	defer context.deinit(t.allocator);

	var builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	{
		const validator = builder.object(&.{}, .{.required = true});
		try t.expectEqual(nullJson, try validator.validateJsonValue(null, &context));
		try t.expectInvalid(.{.code = codes.REQUIRED}, context);
	}

	{
		t.reset(&context);
		const validator = builder.object(&.{}, .{.required = false});
		try t.expectEqual(nullJson, try validator.validateJsonValue(null, &context));
		try t.expectEqual(true, context.isValid());
	}
}

test "object: type" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 2}, {});
	defer context.deinit(t.allocator);

	var builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const validator = builder.object(&.{}, .{});
	try t.expectEqual(nullJson, try validator.validateJsonValue(.{.String = "Hi"}, &context));
	try t.expectInvalid(.{.code = codes.TYPE_OBJECT}, context);
}

test "object: field" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 2}, {});
	defer context.deinit(t.allocator);

	var builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const nameValidator = builder.string(.{.required = true, .min = 3});
	const objectValidator = builder.object(&.{
		builder.field("name", &nameValidator),
	}, .{});

	_ = try objectValidator.validateJsonS("{}", &context);

	try t.expectInvalid(.{.code = codes.REQUIRED, .field = "name"}, context);
}

test "object: nested" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 10, .max_nesting = 2}, {});
	defer context.deinit(t.allocator);

	var builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const ageValidator = builder.int(.{.required = true});
	const nameValidator = builder.string(.{.required = true});
	const scoreValidator = builder.float(.{.required = true});
	const enabledValidator = builder.boolean(.{.required = true});
	const userValidator = builder.object(&.{
		builder.field("age", &ageValidator),
		builder.field("name", &nameValidator),
		builder.field("score", &scoreValidator),
		builder.field("enabled", &enabledValidator),
	}, .{.required = true});
	const dataValidator = builder.object(&.{builder.field("user", &userValidator)}, .{});

	{
		_ = try dataValidator.validateJsonS("{}", &context);
		try t.expectInvalid(.{.code = codes.REQUIRED, .field = "user"}, context);
	}

	{
		t.reset(&context);
		_ = try dataValidator.validateJsonS("{\"user\": 3}", &context);
		try t.expectInvalid(.{.code = codes.TYPE_OBJECT, .field = "user"}, context);
	}

	{
		t.reset(&context);
		_ = try dataValidator.validateJsonS("{\"user\": {}}", &context);
		try t.expectInvalid(.{.code = codes.REQUIRED, .field = "user.age"}, context);
		try t.expectInvalid(.{.code = codes.REQUIRED, .field = "user.name"}, context);
		try t.expectInvalid(.{.code = codes.REQUIRED, .field = "user.score"}, context);
		try t.expectInvalid(.{.code = codes.REQUIRED, .field = "user.enabled"}, context);
	}
}

test "object: change value" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 2}, {});
	defer context.deinit(t.allocator);

	var builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const nameValidator = builder.string(.{.function = testObjectChangeValue});
	const objectValidator = builder.object(&.{
		builder.field("name", &nameValidator),
	}, .{});

	{
		const typed = try objectValidator.validateJsonS("{\"name\": \"normal\"}", &context) orelse unreachable;
		try t.expectEqual(true, context.isValid());
		try t.expectString("normal", typed.string("name").?);
	}

	{
		const typed = try objectValidator.validateJsonS("{\"name\": \"!\"}", &context) orelse unreachable;
		try t.expectEqual(true, context.isValid());
		try t.expectString("abc", typed.string("name").?);
	}
}

fn testObjectChangeValue(value: ?[]const u8, _: *Context(void)) !?[]const u8 {
	if (value.?[0] == '!') {
		return "abc";
	}
	return null;
}

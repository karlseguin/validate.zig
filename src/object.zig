const std = @import("std");
const json = std.json;

const v = @import("validate.zig");
const codes = @import("codes.zig");
const typed = @import("typed");
const Builder = @import("builder.zig").Builder;
const Context = @import("context.zig").Context;
const Validator = @import("validator.zig").Validator;

const Allocator = std.mem.Allocator;

const INVALID_TYPE = v.Invalid{
	.code = codes.TYPE_OBJECT,
	.err = "must be an object",
};

pub const Field = struct {
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
};

pub fn FieldValidator(comptime S: type) type {
	return struct {
		field: Field,
		validator: Validator(S),
	};
}

pub fn Object(comptime S: type) type {
	return struct {
		required: bool,
		fields: std.StringHashMap(FieldValidator(S)),
		function: ?*const fn(value: ?typed.Map, context: *Context(S)) anyerror!?typed.Map,

		const Self = @This();

		pub const Config = struct {
			required: bool = false,
			nest: ?[]const []const u8 = null,
			function: ?*const fn(value: ?typed.Map, context: *Context(S)) anyerror!?typed.Map = null,
		};

		pub fn init(_: Allocator, fields: std.StringHashMap(FieldValidator(S)), config: Config) !Self {
			return .{
				.fields = fields,
				.function = config.function,
				.required = config.required,
			};
		}

		pub fn validator(self: *Self) Validator(S) {
			return Validator(S).init(self);
		}

		pub fn nestField(self: *Self, allocator: Allocator, parent: *Field) !void {
			const parent_path = parent.path;
			const parent_parts = parent.parts;

			var it = self.fields.valueIterator();
			while (it.next()) |fv| {
				var field = &fv.field;
				field.path = try std.fmt.allocPrint(allocator, "{s}.{s}", .{parent_path, field.path});
				if (parent_parts) |pp| {
					const parts = field.parts orelse &([_][]const u8{field.name});
					var new_parts = try allocator.alloc([]const u8, pp.len + parts.len);
					for (pp, 0..) |p, i| {
						new_parts[i] = p;
					}
					for (parts, 0..) |p, i| {
						new_parts[pp.len + i] = p;
					}
					field.parts = new_parts;
				}
			}
		}

		pub fn validateJsonS(self: *Self, data: []const u8, context: *Context(S)) !typed.Map {
			const allocator = context.allocator; // an arena allocator
			var parser = std.json.Parser.init(allocator, .alloc_always);
			defer parser.deinit();

			var tree = parser.parse(data) catch return error.InvalidJson;

			return self.validateJsonV(tree.root, context);
		}

		pub fn validateJsonV(self: *Self, optional_json_value: ?std.json.Value, context: *Context(S)) !typed.Map {
			var typed_value: ?typed.Value = null;
			if (optional_json_value) |json_value| {
				typed_value = switch (json_value) {
					.null => .{.null = {}},
					.object => try typed.fromJson(context.allocator, json_value),
					else => {
						try context.add(INVALID_TYPE);
						return typed.Map.readonlyEmpty();
					}
				};
			}

			return switch (try self.validateValue(typed_value, context)) {
				.null => typed.Map.readonlyEmpty(),
				.map => |map| map,
				else => unreachable,
			};
		}

		pub fn validateValue(self: *const Self, optional_value: ?typed.Value, context: *Context(S)) !typed.Value {
			var map_value: ?typed.Map = null;
			if (optional_value) |untyped_value| {
				map_value = switch (untyped_value) {
					.map => |map| map,
					else => {
						try context.add(INVALID_TYPE);
						return .{.null = {}};
					}
				};
			}

			if (try self.validate(map_value, context)) |value| {
				return .{.map = value};
			}
			return .{.null = {}};
		}

		pub fn validate(self: *const Self, optional_value: ?typed.Map, context: *Context(S)) !?typed.Map {
			var value = optional_value orelse {
				if (self.required) {
					try context.add(v.required);
					return null;
				}
				return self.executeFunction(null, context);
			};

			context.object = value;

			const fields = self.fields;
			var it = fields.valueIterator();
			while (it.next()) |fv| {
				const f = fv.field;
				context.field = f;
				const name = f.name;

				if (value.m.getEntry(name)) |entry| {
					entry.value_ptr.* = try fv.validator.validateValue(entry.value_ptr.*, context);
				} else {
					try value.put(name, try fv.validator.validateValue(null, context));
				}
			}

			return self.executeFunction(value, context);
		}

		fn executeFunction(self: *const Self, value: ?typed.Map, context: *Context(S)) !?typed.Map {
			if (self.function) |f| {
				return f(value, context);
			}
			return value;
		}
	};
}

const t = @import("t.zig");
const nullValue = typed.Value{.null = {}};
test "object: invalidJson" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 2}, {});
	defer context.deinit(t.allocator);

	var builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const object_validator = builder.object(&.{}, .{});

	try t.expectError(error.InvalidJson, object_validator.validateJsonS("{a", &context));
}

test "object: required" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 2}, {});
	defer context.deinit(t.allocator);

	var builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	{
		const validator = builder.object(&.{}, .{.required = true});
		try t.expectEqual(nullValue, try validator.validateValue(null, &context));
		try t.expectInvalid(.{.code = codes.REQUIRED}, context);
	}

	{
		t.reset(&context);
		const validator = builder.object(&.{}, .{.required = false});
		try t.expectEqual(nullValue, try validator.validateValue(null, &context));
		try t.expectEqual(true, context.isValid());
	}
}

test "object: type" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 2}, {});
	defer context.deinit(t.allocator);

	var builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const validator = builder.object(&.{}, .{});
	try t.expectEqual(nullValue, try validator.validateValue(.{.string = "Hi"}, &context));
	try t.expectInvalid(.{.code = codes.TYPE_OBJECT}, context);
}

test "object: field" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 2}, {});
	defer context.deinit(t.allocator);

	var builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const name_validator = builder.string(.{.required = true, .min = 3});
	const object_validator = builder.object(&.{
		builder.field("name", name_validator),
	}, .{});

	_ = try object_validator.validateJsonS("{}", &context);
	try t.expectInvalid(.{.code = codes.REQUIRED, .field = "name"}, context);
}

test "object: nested" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 10, .max_nesting = 2}, {});
	defer context.deinit(t.allocator);

	var builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const id_validator = builder.uuid(.{.required = true});
	const age_validator = builder.int(.{.required = true});
	const any_validator = builder.any(.{.required = true});
	const name_validator = builder.string(.{.required = true});
	const score_validator = builder.float(.{.required = true});
	const enabled_validator = builder.boolean(.{.required = true});
	const user_validator = builder.object(&.{
		builder.field("id", id_validator),
		builder.field("any", any_validator),
		builder.field("age", age_validator),
		builder.field("name", name_validator),
		builder.field("score", score_validator),
		builder.field("enabled", enabled_validator),
	}, .{.required = true});
	const dataValidator = builder.object(&.{builder.field("user", user_validator)}, .{});

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
		try t.expectInvalid(.{.code = codes.REQUIRED, .field = "user.id"}, context);
		try t.expectInvalid(.{.code = codes.REQUIRED, .field = "user.any"}, context);
		try t.expectInvalid(.{.code = codes.REQUIRED, .field = "user.age"}, context);
		try t.expectInvalid(.{.code = codes.REQUIRED, .field = "user.name"}, context);
		try t.expectInvalid(.{.code = codes.REQUIRED, .field = "user.score"}, context);
		try t.expectInvalid(.{.code = codes.REQUIRED, .field = "user.enabled"}, context);
	}
}

test "object: forced nesting" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 10, .max_nesting = 2}, {});
	defer context.deinit(t.allocator);

	var builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const age_validator = builder.int(.{.required = true});
	const user_validator = builder.object(&.{
		builder.field("age", age_validator),
	}, .{.nest = &[_][]const u8{"user"}});

	{
		_ = try user_validator.validateJsonS("{}", &context);
		try t.expectInvalid(.{.code = codes.REQUIRED, .field = "user.age"}, context);
	}
}

test "object: change value" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 2}, {});
	defer context.deinit(t.allocator);

	var builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const name_validator = builder.string(.{.function = testObjectChangeValue});
	const object_validator = builder.object(&.{
		builder.field("name", name_validator),
	}, .{});

	{
		const to = try object_validator.validateJsonS("{\"name\": \"normal\", \"c\": 33}", &context);
		try t.expectEqual(true, context.isValid());
		try t.expectString("normal", to.get([]const u8, "name").?);
	}

	{
		const to = try object_validator.validateJsonS("{\"name\": \"!\", \"c\":33}", &context);
		try t.expectEqual(true, context.isValid());
		try t.expectString("abc", to.get([]u8, "name").?);
	}
}

fn testObjectChangeValue(value: ?[]const u8, ctx: *Context(void)) !?[]const u8 {
	std.debug.assert(ctx.object.get(i64, "c").? == 33);

	if (value.?[0] == '!') {
		return "abc";
	}
	return value;
}

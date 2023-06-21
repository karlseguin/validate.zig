const std = @import("std");
const typed = @import("typed");

const v = @import("validate.zig");
const Validator = @import("validator.zig").Validator;

const codes = v.codes;
const Builder = v.Builder;
const Context = v.Context;
const DataBuilder = v.DataBuilder;

const json = std.json;
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
		min: ?usize,
		max: ?usize,
		invalid_min: ?v.Invalid,
		invalid_max: ?v.Invalid,
		fields: std.StringHashMap(FieldValidator(S)),
		function: ?*const fn(value: ?typed.Map, context: *Context(S)) anyerror!?typed.Map,

		const Self = @This();

		pub const Config = struct {
			required: bool = false,
			min: ?usize = null,
			max: ?usize = null,
			nest: ?[]const []const u8 = null,
			function: ?*const fn(value: ?typed.Map, context: *Context(S)) anyerror!?typed.Map = null,
		};

		pub fn init(allocator: Allocator, fields: std.StringHashMap(FieldValidator(S)), config: Config) !Self {
			var invalid_min: ?v.Invalid = null;
			if (config.min) |m| {
				const plural = if (m == 1) "" else "s";
				invalid_min = v.Invalid{
					.code = codes.OBJECT_LEN_MIN,
					.data = try DataBuilder.init(allocator).put("min", m).done(),
					.err = try std.fmt.allocPrint(allocator, "must have at least {d} item{s}", .{m, plural}),
				};
			}

			var invalid_max: ?v.Invalid = null;
			if (config.max) |m| {
				const plural = if (m == 1) "" else "s";
				invalid_max = v.Invalid{
					.code = codes.OBJECT_LEN_MAX,
					.data = try DataBuilder.init(allocator).put("max", m).done(),
					.err = try std.fmt.allocPrint(allocator, "must have no more than {d} item{s}", .{m, plural}),
				};
			}

			return .{
				.fields = fields,
				.min = config.min,
				.max = config.max,
				.required = config.required,
				.invalid_min = invalid_min,
				.invalid_max = invalid_max,
				.function = config.function,
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

			const count = value.count();
			if (self.min) |m| {
				std.debug.assert(self.invalid_min != null);
				if (count < m) {
					try context.add(self.invalid_min.?);
					return null;
				}
			}

			if (self.max) |m| {
				std.debug.assert(self.invalid_max != null);
				if (count > m) {
					try context.add(self.invalid_max.?);
					return null;
				}
			}

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
					switch (try fv.validator.validateValue(null, context)) {
						.null => {},
						else => |new_value| try value.put(name, new_value),
					}
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

test "object: min" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 2}, {});
	defer context.deinit(t.allocator);

	var builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const validator = builder.object(&.{}, .{.min = 2});
	{
		_ = try validator.validateJsonS("{\"a\": 1}", &context);
		try t.expectInvalid(.{.code = codes.OBJECT_LEN_MIN, .data = .{.min = 2}}, context);
	}

	{
		t.reset(&context);
		_ = try validator.validateJsonS("{\"a\": 1, \"b\": 2}", &context);
		try t.expectEqual(true, context.isValid());
	}
}

test "object: max" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 2}, {});
	defer context.deinit(t.allocator);

	var builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const validator = builder.object(&.{}, .{.max = 2});
	{
		_ = try validator.validateJsonS("{\"a\": 1, \"b\": 2, \"c\": 3}", &context);
		try t.expectInvalid(.{.code = codes.OBJECT_LEN_MAX, .data = .{.max = 2}}, context);
	}

	{
		t.reset(&context);
		_ = try validator.validateJsonS("{\"a\": 1, \"b\": 2}", &context);
		try t.expectEqual(true, context.isValid());
	}
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
	const age_validator = builder.int(i64, .{.required = true});
	const any_validator = builder.any(.{.required = true});
	const name_validator = builder.string(.{.required = true});
	const score_validator = builder.float(f64, .{.required = true});
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

	{
		t.reset(&context);
		_ = try dataValidator.validateJsonS("{\"user\": {\"id\": \"fb1d682b-9c62-49fc-b32c-8a8062a86c14\",\"any\":3,\"age\": 901,\"name\":\"Leto\",\"score\":3.14,\"enabled\":true}}", &context);
		try t.expectEqual(true, context.isValid());
	}
}

test "object: forced nesting" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 10, .max_nesting = 2}, {});
	defer context.deinit(t.allocator);

	var builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const age_validator = builder.int(i64, .{.required = true});
	const user_validator = builder.object(&.{
		builder.field("age", age_validator),
	}, .{.nest = &[_][]const u8{"user"}});

	{
		_ = try user_validator.validateJsonS("{}", &context);
		try t.expectInvalid(.{.code = codes.REQUIRED, .field = "user.age"}, context);
	}
}

test "object: force_prefix" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 10, .max_nesting = 2}, {});
	defer context.deinit(t.allocator);

	var builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const age_validator = builder.int(i64, .{.required = true});
	const user_validator = builder.object(&.{
		builder.field("age", age_validator),
	}, .{.nest = &[_][]const u8{"user"}});

	{
		context.force_prefix = "data";
		_ = try user_validator.validateJsonS("{}", &context);
		try t.expectInvalid(.{.code = codes.REQUIRED, .field = "data.user.age"}, context);
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

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
		remove_unknown: bool,
		fields: std.StringHashMap(FieldValidator(S)),
		function: ?*const fn(value: ?json.ObjectMap, context: *Context(S)) anyerror!?json.ObjectMap,

		const Self = @This();

		pub const Config = struct {
			required: bool = false,
			remove_unknown: bool = false,
			nest: ?[]const []const u8 = null,
			function: ?*const fn(value: ?json.ObjectMap, context: *Context(S)) anyerror!?json.ObjectMap = null,
		};

		pub fn init(_: Allocator, fields: std.StringHashMap(FieldValidator(S)), config: Config) !Self {
			return .{
				.fields = fields,
				.function = config.function,
				.required = config.required,
				.remove_unknown = config.remove_unknown,
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

		pub fn validateJsonS(self: *Self, data: []const u8, context: *Context(S)) Result {
			const allocator = context.allocator; // an arena allocator
			var parser = std.json.Parser.init(allocator, false);
			var tree = parser.parse(data) catch |err| {
				return .{.json = err};
			};
			return self.validateJsonV(tree.root, context);
		}

		pub fn validateJsonV(self: *Self, root: ?json.Value, context: *Context(S)) Result {
			const initial_errors = context._error_len;

			const result = self.validateJsonValue(root, context) catch |err| {
				return .{.err = err};
			};

			var typed = Typed.empty;
			if (result) |value| {
				typed = Typed{.root = value.Object};
			} else if (root) |r| {
				switch (r) {
					.Object => |o| typed = Typed.wrap(o),
					else => {},
				}
			}

			if (context._error_len != initial_errors) {
				return .{.invalid = .{.input = typed, .errors = context.errors()}};
			}
			return .{.ok = typed};
		}

		pub fn validateJsonValue(self: *const Self, optional_value: ?json.Value, context: *Context(S)) !?json.Value {
			const untyped_value = optional_value orelse {
				if (self.required) {
					try context.add(v.required);
				}
				return self.executeFunction(null, context);
			};

			var value = switch (untyped_value) {
				.Object => |o| o,
				else => {
					try context.add(INVALID_TYPE);
					return null;
				},
			};

			context.object = Typed.wrap(value);

			const fields = self.fields;
			var it = fields.valueIterator();
			while (it.next()) |fv| {
				const f = fv.field;
				context.field = f;
				const name = f.name;
				if (value.getEntry(name)) |entry| {
					if (try fv.validator.validateJsonValue(entry.value_ptr.*, context)) |new_field_value| {
						entry.value_ptr.* = new_field_value;
					}
				} else {
					if (try fv.validator.validateJsonValue(null, context)) |new_field_value| {
						try value.put(name, new_field_value);
					}
				}
			}

			const result = try self.executeFunction(value, context);
			if (self.remove_unknown) {
				var map = if (result) |r| r.Object else value;

				var i: usize = 0;
				const keys = map.keys();
				var number_of_keys = keys.len;
				while (i < number_of_keys) {
					var key = keys[i];
					if (fields.contains(key)) {
						i += 1;
						continue;
					}
					map.swapRemoveAt(i);
					number_of_keys -= 1;
				}
				return .{.Object = map};
			} else {
				return result;
			}
		}

		fn executeFunction(self: *const Self, value: ?json.ObjectMap, context: *Context(S)) !?json.Value {
			if (self.function) |f| {
				const transformed = try f(value, context) orelse return null;
				return json.Value{.Object = transformed};
			}
			return null;
		}
	};
}

pub const ResultTag = enum {
	ok,
	err,
	json,
	invalid,
};

pub const Result = union(ResultTag) {
	ok: Typed,
	err: anyerror,
	json: anyerror,
	invalid: Invalid,

	const Invalid = struct {
		input: Typed,
		errors: []v.InvalidField,
	};
};

const nullJson = @as(?json.Value, null);
test "object: invalidJson" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 2}, {});
	defer context.deinit(t.allocator);

	var builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const object_validator = builder.object(&.{}, .{});

	switch (object_validator.validateJsonS("{a", &context)) {
		.json => {},
		else => unreachable,
	}
}

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

	const name_validator = builder.string(.{.required = true, .min = 3});
	const object_validator = builder.object(&.{
		builder.field("name", name_validator),
	}, .{});

	const errors = object_validator.validateJsonS("{}", &context).invalid.errors;
	try t.expectInvalidErrors(.{.code = codes.REQUIRED, .field = "name"}, errors);
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
		const errors = dataValidator.validateJsonS("{}", &context).invalid.errors;
		try t.expectInvalidErrors(.{.code = codes.REQUIRED, .field = "user"}, errors);
	}

	{
		t.reset(&context);
		const errors = dataValidator.validateJsonS("{\"user\": 3}", &context).invalid.errors;
		try t.expectInvalidErrors(.{.code = codes.TYPE_OBJECT, .field = "user"}, errors);
	}

	{
		t.reset(&context);
		_ = dataValidator.validateJsonS("{\"user\": {}}", &context);
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
		_ = user_validator.validateJsonS("{}", &context);
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
		const typed = object_validator.validateJsonS("{\"name\": \"normal\", \"c\": 33}", &context).ok;
		try t.expectEqual(true, context.isValid());
		try t.expectString("normal", typed.string("name").?);
	}

	{
		const typed = object_validator.validateJsonS("{\"name\": \"!\", \"c\":33}", &context).ok;
		try t.expectEqual(true, context.isValid());
		try t.expectString("abc", typed.string("name").?);
	}
}

test "object: remove_unknown" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 2}, {});
	defer context.deinit(t.allocator);

	var builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const object_validator = builder.object(&.{
		builder.field("id", builder.int(.{})),
		builder.field("name", builder.string(.{.min = 4})),
	}, .{.remove_unknown = true});

	const out = object_validator.validateJsonS("{\"f\": 32.2, \"id\":4, \"name\": \"abcd\", \"other\": true}", &context).ok;
	const keys = out.root.keys();
	try t.expectEqual(@as(usize, 2), keys.len);
	try t.expectString("name", keys[0]);
	try t.expectString("id", keys[1]);
}

fn testObjectChangeValue(value: ?[]const u8, ctx: *Context(void)) !?[]const u8 {
	std.debug.assert(ctx.object.int("c").? == 33);

	if (value.?[0] == '!') {
		return "abc";
	}
	return null;
}

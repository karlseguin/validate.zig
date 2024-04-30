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
	.code = codes.TYPE_ARRAY,
	.err = "must be an array",
};

const INVALID_JSON = v.Invalid{
	.code = codes.INVALID_JSON,
	.err = "is not a valid JSON string",
};

pub fn Array(comptime S: type) type {
	return struct {
		parse: bool,
		required: bool,
		min: ?usize,
		max: ?usize,
		invalid_min: ?v.Invalid,
		invalid_max: ?v.Invalid,
		_validator: ?Validator(S),
		function: ?*const fn(value: ?typed.Array, context: *Context(S)) anyerror!?typed.Array,

		const Self = @This();

		pub const Config = struct {
			parse: bool = false,
			required: bool = false,
			min: ?usize = null,
			max: ?usize = null,
			function: ?*const fn(value: ?typed.Array, context: *Context(S)) anyerror!?typed.Array = null,
		};

		pub fn init(allocator: Allocator, item_validator: anytype, config: Config) !Self {
			var invalid_min: ?v.Invalid = null;
			if (config.min) |m| {
				const plural = if (m == 1) "" else "s";
				invalid_min = v.Invalid{
					.code = codes.ARRAY_LEN_MIN,
					.data = try DataBuilder.init(allocator).put("min", m).done(),
					.err = try std.fmt.allocPrint(allocator, "must have at least {d} item{s}", .{m, plural}),
				};
			}

			var invalid_max: ?v.Invalid = null;
			if (config.max) |m| {
				const plural = if (m == 1) "" else "s";
				invalid_max = v.Invalid{
					.code = codes.ARRAY_LEN_MAX,
					.data = try DataBuilder.init(allocator).put("max", m).done(),
					.err = try std.fmt.allocPrint(allocator, "must have no more than {d} item{s}", .{m, plural}),
				};
			}

			var val: ?Validator(S) = null;
			if (@TypeOf(item_validator) != @TypeOf(null)) {
				val = item_validator.validator();
			}

			return .{
				.min = config.min,
				.max = config.max,
				.parse = config.parse,
				.required = config.required,
				.invalid_min = invalid_min,
				.invalid_max = invalid_max,
				.function = config.function,
				._validator = val,
			};
		}

		pub fn validator(self: *Self) Validator(S) {
			return Validator(S).init(self);
		}

		pub fn nestField(self: *Self, allocator: Allocator, parent: *v.Field) !void {
			const path = parent.path;
			// The first time this validator is added to an object, we create the parts
			// On subsequent nesting, we don't need to do anything (the Object validator
			// will prepend the parent's parts this)
			if (parent.parts == null) {
				var parts = try allocator.alloc([]const u8, 2);
				parts[0] = path;
				parts[1] = "";
				parent.parts = parts;
			}

			// we still need to notify our validator of the nesting
			if (self._validator) |child| {
				try child.nestField(allocator, parent);
			}
		}

		pub fn validateValue(self: *const Self, optional_value: ?typed.Value, context: *Context(S)) !typed.Value {
			var array_value: ?typed.Array = null;
			if (optional_value) |untyped_value| {
				var invalid: ?v.Invalid = null;

				switch (untyped_value) {
					.array => |a| array_value = a,
					.string => |str| blk: {
						if (self.parse) {
							const json_value = std.json.parseFromSliceLeaky(std.json.Value, context.allocator, str, .{}) catch {
								invalid = INVALID_JSON;
								break :blk;
							};
							switch (try typed.fromJson(context.allocator, json_value)) {
								.array => |a|  array_value = a,
								else => {
									invalid = INVALID_TYPE;
								},
							}
						} else {
							invalid = INVALID_TYPE;
						}
					},
					else => invalid = INVALID_TYPE
				}

				if (invalid) |inv| {
					try context.add(inv);
					return .{.null = {}};
				}
			}

			if (try self.validate(array_value, context)) |value| {
				return .{.array = value};
			}
			return .{.null = {}};
		}

		pub fn validate(self: *const Self, optional_value: ?typed.Array, context: *Context(S)) !?typed.Array {
			const value = optional_value orelse {
				if (self.required) {
					try context.add(v.required);
					return null;
				}
				return self.executeFunction(null, context);
			};

			const items = value.items;

			if (self.min) |m| {
				if (items.len < m) {
					try context.add(self.invalid_min.?);
					return null;
				}
			}

			if (self.max) |m| {
				if (items.len > m) {
					try context.add(self.invalid_max.?);
					return null;
				}
			}

			if (self._validator) |val| {
				context.startArray();
				defer context.endArray();
				for (items, 0..) |item, i| {
					context.arrayIndex(i);
					items[i] = try val.validateValue(item, context);
				}
			}

			return self.executeFunction(value, context);
		}

		fn executeFunction(self: *const Self, value: ?typed.Array, context: *Context(S)) !?typed.Array {
			if (self.function) |f| {
				return f(value, context);
			}
			return value;
		}
	};
}

const t = @import("t.zig");
const nullValue = typed.Value{.null = {}};
test "array: required" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 2}, {});
	defer context.deinit(t.allocator);

	const builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	{
		const validator = builder.array(null, .{.required = true});
		try t.expectEqual(nullValue, try validator.validateValue(null, &context));
		try t.expectInvalid(.{.code = codes.REQUIRED}, context);
	}

	{
		t.reset(&context);
		const validator = builder.array(null, .{.required = false});
		try t.expectEqual(nullValue, try validator.validateValue(null, &context));
		try t.expectEqual(true, context.isValid());
	}
}

test "array: type" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 2}, {});
	defer context.deinit(t.allocator);

	const builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const validator = builder.array(null, .{});
	try t.expectEqual(nullValue, try validator.validateValue(.{.string = "Hi"}, &context));
	try t.expectInvalid(.{.code = codes.TYPE_ARRAY}, context);
}

test "array: min length" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 2}, {});
	defer context.deinit(t.allocator);

	const builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const arrayValidator = builder.array(null, .{.min = 2});
	const objectValidator = builder.object(&.{
		builder.field("items", arrayValidator),
	}, .{});

	{
		_ = try objectValidator.validateJsonS("{\"items\": []}", &context);
		try t.expectInvalid(.{.code = codes.ARRAY_LEN_MIN}, context);
	}

	{
		t.reset(&context);
		_ = try objectValidator.validateJsonS("{\"items\": [1]}", &context);
		try t.expectInvalid(.{.code = codes.ARRAY_LEN_MIN}, context);
	}

	{
		t.reset(&context);
		_ = try objectValidator.validateJsonS("{\"items\": [1, 2]}", &context);
		try t.expectEqual(true, context.isValid());
	}
}

test "array: max length" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 2}, {});
	defer context.deinit(t.allocator);

	const builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const arrayValidator = builder.array(null, .{.max = 3});
	const objectValidator = builder.object(&.{
		builder.field("items", arrayValidator),
	}, .{});

	{
		_ = try objectValidator.validateJsonS("{\"items\": [1, 2, 3, 4]}", &context);
		try t.expectInvalid(.{.code = codes.ARRAY_LEN_MAX}, context);
	}

	{
		t.reset(&context);
		_ = try objectValidator.validateJsonS("{\"items\": [1, 2, 3]}", &context);
		try t.expectEqual(true, context.isValid());
	}

	{
		t.reset(&context);
		_ = try objectValidator.validateJsonS("{\"items\": [1, 2]}", &context);
		try t.expectEqual(true, context.isValid());
	}
}

test "array: nested" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 2}, {});
	defer context.deinit(t.allocator);

	const builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const itemValidator = builder.int(i64, .{.min = 4});
	const arrayValidator = builder.array(itemValidator, .{});
	const objectValidator = builder.object(&.{
		builder.field("items", arrayValidator),
	}, .{});

	{
		_ = try objectValidator.validateJsonS("{\"items\": [1, 2, 5]}", &context);
		try t.expectInvalid(.{.code = codes.INT_MIN, .field = "items.0"}, context);
		try t.expectInvalid(.{.code = codes.INT_MIN, .field = "items.1"}, context);
	}
}

test "array: deeplys nested field name" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 2}, {});
	defer context.deinit(t.allocator);

	const builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const favValidator = builder.int(i64, .{.min = 4});
	const favArrayValidator = builder.array(favValidator, .{.required = true});
	const itemValidator = builder.object(&.{builder.field("fav", favArrayValidator)}, .{});
	const itemsArrayValidator = builder.array(itemValidator, .{});
	const objectValidator = builder.object(&.{builder.field("items", itemsArrayValidator)}, .{});

	{
		_ = try objectValidator.validateJsonS("{\"items\": [{\"fav\": [1,2]}]}", &context);
		try t.expectInvalid(.{.code = codes.INT_MIN, .field = "items.0.fav.0"}, context);
		try t.expectInvalid(.{.code = codes.INT_MIN, .field = "items.0.fav.1"}, context);
	}

	{
		t.reset(&context);
		_ = try objectValidator.validateJsonS("{\"items\": [{}]}", &context);
		try t.expectInvalid(.{.code = codes.REQUIRED, .field = "items.0.fav"}, context);
	}
}

test "array: change value" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 2}, {});
	defer context.deinit(t.allocator);

	const builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const itemValidator = builder.int(i64, .{.function = testArrayChangeValue});
	const arrayValidator = builder.array(itemValidator, .{});
	const objectValidator = builder.object(&.{
		builder.field("items", arrayValidator),
	}, .{});

	{
		const to = try objectValidator.validateJsonS("{\"items\": [1, 2, -5]}", &context);
		try t.expectEqual(true, context.isValid());

		const items = to.get("items").?.array.items;
		try t.expectEqual(@as(i64, -1), items[0].i64);
		try t.expectEqual(@as(i64, 2), items[1].i64);
		try t.expectEqual(@as(i64, -5), items[2].i64);
	}
}

test "array: function" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 2}, {});
	defer context.deinit(t.allocator);

	const builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const arrayValidator = builder.array(null, .{.function = testArrayValidator});
	const objectValidator = builder.object(&.{
		builder.field("items", arrayValidator),
	}, .{});

	{
		const to = try objectValidator.validateJsonS("{\"items\": [2]}", &context);
		try t.expectEqual(true, context.isValid());

		const items = to.get("items").?.array.items;
		try t.expectEqual(@as(i64, 9001), items[0].i64);
	}

	{
		const to = try objectValidator.validateJsonS("{\"items\": [2, 3]}", &context);
		try t.expectEqual(true, context.isValid());

		const items = to.get("items").?.array.items;
		try t.expectEqual(@as(i64, 2), items[0].i64);
		try t.expectEqual(@as(i64, 3), items[1].i64);
	}
}

fn testArrayChangeValue(value: ?i64, _: *Context(void)) !?i64 {
	if (value.? == 1) return -1;
	return value;
}

fn testArrayValidator(value: ?typed.Array, _: *Context(void)) !?typed.Array {
	const n = value orelse unreachable;

	if (n.items.len == 1) {
		n.items[0] = .{.i64 = 9001};
		return n;
	}

	return value;
}

const std = @import("std");
const json = std.json;

const t = @import("t.zig");

const v = @import("validate.zig");
const codes = @import("codes.zig");
const Builder = @import("builder.zig").Builder;
const Context = @import("context.zig").Context;
const Validator = @import("validator.zig").Validator;

const Allocator = std.mem.Allocator;

const INVALID_TYPE = v.Invalid{
	.code = codes.TYPE_ARRAY,
	.err = "must be an array",
};

pub fn Array(comptime S: type) type {
	return struct {
		required: bool,
		min: ?usize,
		max: ?usize,
		invalid_min: ?v.Invalid,
		invalid_max: ?v.Invalid,
		_validator: ?Validator(S),

		const Self = @This();

		pub const Config = struct {
			required: bool = false,
			min: ?usize = null,
			max: ?usize = null,
		};

		pub fn init(allocator: Allocator, optional_validator: anytype, config: Config) !Self {
			var invalid_min: ?v.Invalid = null;
			if (config.min) |m| {
				invalid_min = v.Invalid{
					.code = codes.ARRAY_LEN_MIN,
					.data = .{.imin = .{.min = @intCast(i64, m) }},
					.err = try std.fmt.allocPrint(allocator, "must have at least {d} items", .{m}),
				};
			}

			var invalid_max: ?v.Invalid = null;
			if (config.max) |m| {
				invalid_max = v.Invalid{
					.code = codes.ARRAY_LEN_MAX,
					.data = .{.imax = .{.max = @intCast(i64, m) }},
					.err = try std.fmt.allocPrint(allocator, "must no more than {d} items", .{m}),
				};
			}

			var val: ?Validator(S) = null;
			if (@TypeOf(optional_validator) != @TypeOf(null)) {
				val = optional_validator.validator();
			}

			return .{
				.min = config.min,
				.max = config.max,
				.required = config.required,
				.invalid_min = invalid_min,
				.invalid_max = invalid_max,
				._validator = val,
			};
		}

		pub fn validator(self: *const Self) Validator(S) {
			return Validator(S).init(self);
		}

		pub fn nestField(self: *const Self, allocator: Allocator, parent: *v.Field(S)) !void {
			const path = parent.path;
			// The first time this validator is added to an object, we mutate the path
			// to be: path.#
			// But on subsequent nesting, we don't need to do anything, as the path
			// already has a ".#" suffix, and any extra nesting just changes the prefix
			// which our object validator is taking care of.
			if (path[path.len - 1] != 36) {

				var p = try allocator.alloc(u8, path.len + 2);
				std.mem.copy(u8, p, path);
				p[path.len] = '.';
				p[path.len+1] = 36; // 36 == record separator
				parent.path = p;
			}

			// we still need to notify our validator of the nesting
			if (self._validator) |child| {
				try child.nestField(allocator, parent);
			}
		}

		pub fn validateJsonValue(self: *const Self, optional_value: ?json.Value, context: *Context(S)) !?json.Value {
			const untyped_value = optional_value orelse {
				if (self.required) {
					try context.add(v.required);
				}
				return null;
			};

			var value = switch (untyped_value) {
				.Array => |a| a,
				else => {
					try context.add(INVALID_TYPE);
					return null;
				},
			};

			const items = value.items;

			if (self.min) |m| {
				std.debug.assert(self.invalid_min != null);
				if (items.len < m) {
					try context.add(self.invalid_min.?);
					return null;
				}
			}

			if (self.max) |m| {
				std.debug.assert(self.invalid_max != null);
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
					_ = try val.validateJsonValue(item, context);
				}
			}

			return null;
		}
	};
}

const nullJson = @as(?json.Value, null);
test "array: required" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 2}, {});
	defer context.deinit(t.allocator);

	const builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	{
		const validator = try builder.array(null, .{.required = true});
		try t.expectEqual(nullJson, try validator.validateJsonValue(null, &context));
		try t.expectInvalid(.{.code = codes.REQUIRED}, context);
	}

	{
		context.reset();
		const validator = try builder.array(null, .{.required = false});
		try t.expectEqual(nullJson, try validator.validateJsonValue(null, &context));
		try t.expectEqual(true, context.isValid());
	}
}

test "array: type" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 2}, {});
	defer context.deinit(t.allocator);

	const builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const validator = try builder.array(null, .{});
	try t.expectEqual(nullJson, try validator.validateJsonValue(.{.String = "Hi"}, &context));
	try t.expectInvalid(.{.code = codes.TYPE_ARRAY}, context);
}

test "array: min length" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 2}, {});
	defer context.deinit(t.allocator);

	const builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const arrayValidator = try builder.array(null, .{.min = 2});
	const objectValidator = try builder.object(&.{
		builder.field("items", &arrayValidator),
	}, .{});

	{
		_ = try objectValidator.validateJson("{\"items\": []}", &context);
		try t.expectInvalid(.{.code = codes.ARRAY_LEN_MIN}, context);
	}

	{
		context.reset();
		_ = try objectValidator.validateJson("{\"items\": [1]}", &context);
		try t.expectInvalid(.{.code = codes.ARRAY_LEN_MIN}, context);
	}

	{
		context.reset();
		_ = try objectValidator.validateJson("{\"items\": [1, 2]}", &context);
		try t.expectEqual(true, context.isValid());
	}
}

test "array: max length" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 2}, {});
	defer context.deinit(t.allocator);

	const builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const arrayValidator = try builder.array(null, .{.max = 3});
	const objectValidator = try builder.object(&.{
		builder.field("items", &arrayValidator),
	}, .{});

	{
		_ = try objectValidator.validateJson("{\"items\": [1, 2, 3, 4]}", &context);
		try t.expectInvalid(.{.code = codes.ARRAY_LEN_MAX}, context);
	}

	{
		context.reset();
		_ = try objectValidator.validateJson("{\"items\": [1, 2, 3]}", &context);
		try t.expectEqual(true, context.isValid());
	}

	{
		context.reset();
		_ = try objectValidator.validateJson("{\"items\": [1, 2]}", &context);
		try t.expectEqual(true, context.isValid());
	}
}

test "array: nested field name" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 2}, {});
	defer context.deinit(t.allocator);

	const builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const itemValidator = try builder.int(.{.min = 4});
	const arrayValidator = try builder.array(&itemValidator, .{});
	const objectValidator = try builder.object(&.{
		builder.field("items", &arrayValidator),
	}, .{});

	{
		_ = try objectValidator.validateJson("{\"items\": [1, 2, 5]}", &context);
		try t.expectInvalid(.{.code = codes.INT_MIN, .field = "items.0"}, context);
		try t.expectInvalid(.{.code = codes.INT_MIN, .field = "items.1"}, context);
	}
}

test "array: deeplys nested field name" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 2}, {});
	defer context.deinit(t.allocator);

	const builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const favValidator = try builder.int(.{.min = 4});
	const favArrayValidator = try builder.array(&favValidator, .{});
	const itemValidator = try builder.object(&.{builder.field("fav", &favArrayValidator)}, .{});
	const itemsArrayValidator = try builder.array(&itemValidator, .{});
	const objectValidator = try builder.object(&.{builder.field("items", &itemsArrayValidator)}, .{});

	{
		_ = try objectValidator.validateJson("{\"items\": [{\"fav\": [1,2]}]}", &context);
		try t.expectInvalid(.{.code = codes.INT_MIN, .field = "items.0.fav.0"}, context);
		try t.expectInvalid(.{.code = codes.INT_MIN, .field = "items.0.fav.1"}, context);
	}
}

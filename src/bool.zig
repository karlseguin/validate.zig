const std = @import("std");
const t = @import("t.zig");

const v = @import("validate.zig");
const codes = @import("codes.zig");
const Builder = @import("builder.zig").Builder;
const Context = @import("context.zig").Context;
const Validator = @import("validator.zig").Validator;

const json = std.json;
const Allocator = std.mem.Allocator;

const INVALID_TYPE = v.Invalid{
	.code = codes.TYPE_BOOL,
	.err = "must be a bool",
};

pub fn Bool(comptime S: type) type {
	return struct {
		required: bool,

		const Self = @This();

		pub const Config = struct {
			required: bool = false,
		};

		pub fn init(_: Allocator, config: Config) !Self {
			return .{
				.required = config.required,
			};
		}

		pub fn validator(self: *const Self) Validator(S) {
			return Validator(S).init(self);
		}

		// part of the Validator interface, but noop for bools
		pub fn nestField(_: *const Self, _: Allocator, _: []const u8) !void {}

		pub fn validateJsonValue(self: *const Self, input: ?json.Value, context: *Context(S)) !?json.Value {
			const untyped_value = input orelse {
				if (self.required) {
					try context.add(v.required);
				}
				return null;
			};

			switch (untyped_value) {
				.Bool => return null,
				else => {
					try context.add(INVALID_TYPE);
					return null;
				}
			}
		}
	};
}

const nullJson = @as(?json.Value, null);
test "bool: required" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_depth = 1}, {});
	defer context.deinit(t.allocator);

	const builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	{
		const validator = try builder.boolean(.{.required = true});
		try t.expectEqual(nullJson, try validator.validateJsonValue(null, &context));
		try t.expectInvalid(.{.code = codes.REQUIRED}, context);
	}

	{
		context.reset();
		const validator = try builder.boolean(.{.required = false});
		try t.expectEqual(nullJson, try validator.validateJsonValue(null, &context));
		try t.expectEqual(true, context.isValid());
	}
}

test "bool: type" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_depth = 1}, {});
	defer context.deinit(t.allocator);

	const builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const validator = try builder.boolean(.{});
	{
		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.String = "NOPE"}, &context));
		try t.expectInvalid(.{.code = codes.TYPE_BOOL}, context);
	}

	{
		context.reset();
		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.Bool = true}, &context));
		try t.expectEqual(true, context.isValid());
	}

	{
		context.reset();
		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.Bool = false}, &context));
		try t.expectEqual(true, context.isValid());
	}
}



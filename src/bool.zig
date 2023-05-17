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
		parse: bool,
		required: bool,
		function: ?*const fn(value: ?bool, context: *Context(S)) anyerror!?bool,

		const Self = @This();

		pub const Config = struct {
			parse: bool = false,
			required: bool = false,
			function: ?*const fn(value: ?bool, context: *Context(S)) anyerror!?bool = null,
		};

		pub fn init(_: Allocator, config: Config) !Self {
			return .{
				.parse = config.parse,
				.required = config.required,
				.function = config.function,
			};
		}

		pub fn validator(self: *Self) Validator(S) {
			return Validator(S).init(self);
		}

		pub fn trySetRequired(self: *Self, req: bool, builder: *Builder(S)) !*Bool(S) {
			var clone = try builder.allocator.create(Bool(S));
			clone.* = self.*;
			clone.required = req;
			return clone;
		}
		pub fn setRequired(self: *Self, req: bool, builder: *Builder(S)) *Bool(S) {
			return self.trySetRequired(req, builder) catch unreachable;
		}

		// part of the Validator interface, but noop for bools
		pub fn nestField(_: *Self, _: Allocator, _: *v.Field) !void {}

		pub fn validateJsonValue(self: *const Self, input: ?json.Value, context: *Context(S)) !?json.Value {
			const untyped_value = input orelse {
				if (self.required) {
					try context.add(v.required);
				}
				return self.executeFunction(null, context);
			};

			var parsed = false;
			const value = switch (untyped_value) {
				.Bool => |b| b,
				.String => |s| blk: {
					if (self.parse and s.len > 0) {
						// prematurely set this, either it's true, or it won't matter
						// because we'll return with an INVALID_TYPE error
						parsed = true;
						if (s[0] == '1') break :blk true;
						if (s[0] == 'T') break :blk true;
						if (s[0] == 't') break :blk true;
						if (s[0] == '0') break :blk false;
						if (s[0] == 'F') break :blk false;
						if (s[0] == 'f') break :blk false;
						if (std.ascii.eqlIgnoreCase(s, "true")) break :blk true;
						if (std.ascii.eqlIgnoreCase(s, "false")) break :blk false;
					}
					try context.add(INVALID_TYPE);
					return null;
				},
				else => {
					try context.add(INVALID_TYPE);
					return null;
				}
			};

			if (try self.executeFunction(value, context)) |val| {
				return val;
			}

			if (parsed) {
				return .{.Bool = value};
			}

			return null;
		}

		fn executeFunction(self: *const Self, value: ?bool, context: *Context(S)) !?json.Value {
			if (self.function) |f| {
				const transformed = try f(value, context) orelse return null;
				return json.Value{.Bool = transformed};
			}
			return null;
		}
	};
}

const nullJson = @as(?json.Value, null);
test "bool: required" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 1}, {});
	defer context.deinit(t.allocator);

	var builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const notRequired = builder.boolean(.{.required = false, });
	const required = notRequired.setRequired(true, &builder);

	{
		try t.expectEqual(nullJson, try required.validateJsonValue(null, &context));
		try t.expectInvalid(.{.code = codes.REQUIRED}, context);
	}

	{
		t.reset(&context);
		try t.expectEqual(nullJson, try notRequired.validateJsonValue(null, &context));
		try t.expectEqual(true, context.isValid());
	}

	{
		// test required = false when configured directly (not via setRequired)
		t.reset(&context);
		const validator = builder.boolean(.{.required = false});
		try t.expectEqual(nullJson, try validator.validateJsonValue(null, &context));
		try t.expectEqual(true, context.isValid());
	}
}

test "bool: type" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 1}, {});
	defer context.deinit(t.allocator);

	const builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const validator = builder.boolean(.{});
	{
		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.String = "NOPE"}, &context));
		try t.expectInvalid(.{.code = codes.TYPE_BOOL}, context);
	}

	{
		t.reset(&context);
		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.Bool = true}, &context));
		try t.expectEqual(true, context.isValid());
	}

	{
		t.reset(&context);
		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.Bool = false}, &context));
		try t.expectEqual(true, context.isValid());
	}
}

test "bool: parse" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 1}, {});
	defer context.deinit(t.allocator);

	const builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const validator = builder.boolean(.{.parse = true});

	{
		// still works fine with correct type
		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.Bool = true}, &context));
		try t.expectEqual(true, context.isValid());
	}

	const true_strings = [_][]const u8{"t", "T", "true", "True", "TRUE", "1"};
	for (true_strings) |value| {
		// parses a string and applies the validation on the parsed value
		t.reset(&context);
		try t.expectEqual(true, (try validator.validateJsonValue(.{.String = value}, &context)).?.Bool);
		try t.expectEqual(true, context.isValid());
	}

	const false_strings = [_][]const u8{"f", "F", "false", "False", "FALSE", "0"};
	for (false_strings) |value| {
		// parses a string and applies the validation on the parsed value
		t.reset(&context);
		try t.expectEqual(false, (try validator.validateJsonValue(.{.String = value}, &context)).?.Bool);
		try t.expectEqual(true, context.isValid());
	}
}

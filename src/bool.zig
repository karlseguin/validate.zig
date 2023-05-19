const std = @import("std");

const v = @import("validate.zig");
const typed = @import("typed");
const codes = @import("codes.zig");
const Builder = @import("builder.zig").Builder;
const Context = @import("context.zig").Context;
const Validator = @import("validator.zig").Validator;

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

		pub fn validateValue(self: *const Self, input: ?typed.Value, context: *Context(S)) !typed.Value {
			var bool_value: ?bool = null;
			if (input) |untyped_value| {
				bool_value = switch (untyped_value) {
					.bool => |b| b,
					.string => |s| blk: {
						if (self.parse and s.len > 0) {
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
						return .{.null = {}};
					},
					else => {
						try context.add(INVALID_TYPE);
						return .{.null = {}};
					}
				};
			}

			if (try self.validate(bool_value, context)) |value| {
				return .{.bool = value};
			}
			return .{.null = {}};
		}

		pub fn validate(self: *const Self, optional_value: ?bool, context: *Context(S)) !?bool {
			const value = optional_value orelse {
				if (self.required) {
					try context.add(v.required);
					return null;
				}
				return self.executeFunction(null, context);
			};

			return self.executeFunction(value, context);
		}

		fn executeFunction(self: *const Self, value: ?bool, context: *Context(S)) !?bool {
			if (self.function) |f| {
				return f(value, context);
			}
			return value;
		}
	};
}

const t = @import("t.zig");
const nullValue = typed.Value{.null = {}};
test "bool: required" {
	var context = t.context();
	defer context.deinit(t.allocator);

	var builder = t.builder();
	defer builder.deinit(t.allocator);

	const notRequired = builder.boolean(.{.required = false, });
	const required = notRequired.setRequired(true, &builder);

	{
		try t.expectEqual(@as(?bool, null), try required.validate(null, &context));
		try t.expectInvalid(.{.code = codes.REQUIRED}, context);
	}

	{
		t.reset(&context);
		try t.expectEqual(nullValue, try notRequired.validateValue(null, &context));
		try t.expectEqual(true, context.isValid());
	}

	{
		// test required = false when configured directly (not via setRequired)
		t.reset(&context);
		const validator = builder.boolean(.{.required = false});
		try t.expectEqual(nullValue, try validator.validateValue(null, &context));
		try t.expectEqual(true, context.isValid());
	}
}

test "bool: type" {
	var context = t.context();
	defer context.deinit(t.allocator);

	var builder = t.builder();
	defer builder.deinit(t.allocator);

	const validator = builder.boolean(.{});
	{
		try t.expectEqual(nullValue, try validator.validateValue(.{.string = "NOPE"}, &context));
		try t.expectInvalid(.{.code = codes.TYPE_BOOL}, context);
	}

	{
		t.reset(&context);
		try t.expectEqual(true, (try validator.validateValue(.{.bool = true}, &context)).bool);
		try t.expectEqual(true, context.isValid());
	}

	{
		t.reset(&context);
		try t.expectEqual(false, (try validator.validateValue(.{.bool = false}, &context)).bool);
		try t.expectEqual(true, context.isValid());
	}
}

test "bool: parse" {
	var context = t.context();
	defer context.deinit(t.allocator);

	var builder = t.builder();
	defer builder.deinit(t.allocator);

	const validator = builder.boolean(.{.parse = true});

	{
		// still works fine with correct type
		try t.expectEqual(true, (try validator.validateValue(.{.bool = true}, &context)).bool);
		try t.expectEqual(true, context.isValid());
	}

	const true_strings = [_][]const u8{"t", "T", "true", "True", "TRUE", "1"};
	for (true_strings) |value| {
		// parses a string and applies the validation on the parsed value
		t.reset(&context);
		try t.expectEqual(true, (try validator.validateValue(.{.string = value}, &context)).bool);
		try t.expectEqual(true, context.isValid());
	}

	const false_strings = [_][]const u8{"f", "F", "false", "False", "FALSE", "0"};
	for (false_strings) |value| {
		// parses a string and applies the validation on the parsed value
		t.reset(&context);
		try t.expectEqual(false, (try validator.validateValue(.{.string = value}, &context)).bool);
		try t.expectEqual(true, context.isValid());
	}
}

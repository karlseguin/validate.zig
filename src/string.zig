const std = @import("std");
const t = @import("t.zig");
const re = @cImport(@cInclude("regez.h"));

const v = @import("validate.zig");
const codes = @import("codes.zig");
const Builder = @import("builder.zig").Builder;
const Context = @import("context.zig").Context;
const Validator = @import("validator.zig").Validator;

const json = std.json;
const Allocator = std.mem.Allocator;

const REGEX_T_SIZEOF = re.sizeof_regex_t;
const REGEX_T_ALIGNOF = re.alignof_regex_t;

const INVALID_TYPE = v.Invalid{
	.code = codes.TYPE_STRING,
	.err = "must be a string",
};

pub fn String(comptime S: type) type {
	return struct {
		required: bool,
		min: ?usize,
		max: ?usize,
		choices: ?[]const []const u8 = null,
		function: ?*const fn(value: ?[]const u8, context: *Context(S)) anyerror!?[]const u8,
		invalid_min: ?v.Invalid,
		invalid_max: ?v.Invalid,
		invalid_pattern: ?v.Invalid,
		invalid_choices: ?v.Invalid,
		regex: ?*re.regex_t,

		const Self = @This();

		pub const Config = struct {
			min: ?usize = null,
			max: ?usize = null,
			required: bool = false,
			choices: ?[]const []const u8 = null,
			pattern: ?[]const u8 = null,
			function: ?*const fn(value: ?[]const u8, context: *Context(S)) anyerror!?[]const u8 = null,
		};

		pub fn init(allocator: Allocator, config: Config) !Self {
			var invalid_min: ?v.Invalid = null;
			if (config.min) |m| {
				const plural = if (m == 1) "" else "s";
				invalid_min = v.Invalid{
					.code = codes.STRING_LEN_MIN,
					.data = .{.imin = .{.min = @intCast(i64, m) }},
					.err = try std.fmt.allocPrint(allocator, "must have at least {d} character{s}", .{m, plural}),
				};
			}

			var invalid_max: ?v.Invalid = null;
			if (config.max) |m| {
				const plural = if (m == 1) "" else "s";
				invalid_max = v.Invalid{
					.code = codes.STRING_LEN_MAX,
					.data = .{.imax = .{.max = @intCast(i64, m) }},
					.err = try std.fmt.allocPrint(allocator, "must have no more than {d} character{s}", .{m, plural}),
				};
			}

			var invalid_choices: ?v.Invalid = null;
			var owned_choices: ?[][]const u8 = null;
			if (config.choices) |choices| {
				var owned = try allocator.alloc([]u8, choices.len);
				for (choices, 0..) |choice, i| {
					owned[i] = try allocator.alloc(u8, choice.len);
					std.mem.copy(u8, owned[i], choice);
				}
				owned_choices = owned;

				const choice_list = try std.mem.join(allocator, ", ", owned);
				invalid_choices = v.Invalid{
					.code = codes.STRING_CHOICE,
					.data = .{.choice = .{.valid = owned}},
					.err = try std.fmt.allocPrint(allocator, "must be one of: {s}", .{choice_list}),
				};
			}

			var regex: ?*re.regex_t = null;
			var invalid_pattern: ?v.Invalid = null;
			if (config.pattern) |pattern| {
				regex = try allocateRegex(allocator, pattern);
				invalid_pattern = v.Invalid{
					.err = "is not valid",
					.code = codes.STRING_PATTERN,
					.data = .{.pattern = .{.pattern = pattern}},
				};
			}

			return .{
				.regex = regex,
				.min = config.min,
				.max = config.max,
				.choices = owned_choices,
				.required = config.required,
				.function = config.function,
				.invalid_min = invalid_min,
				.invalid_max = invalid_max,
				.invalid_pattern = invalid_pattern,
				.invalid_choices = invalid_choices,
			};
		}

		pub fn validator(self: *Self) Validator(S) {
			return Validator(S).init(self);
		}

		pub fn trySetRequired(self: *Self, req: bool, builder: *Builder(S)) !*String(S) {
			var clone = try builder.allocator.create(String(S));
			clone.* = self.*;
			clone.required = req;
			return clone;
		}
		pub fn setRequired(self: *Self, req: bool, builder: *Builder(S)) *String(S) {
			return self.trySetRequired(req, builder) catch unreachable;
		}

		// part of the Validator interface, but noop for strings
		pub fn nestField(_: *Self, _: Allocator, _: *v.Field) !void {}

		pub fn validateJsonValue(self: *const Self, input: ?json.Value, context: *Context(S)) !?json.Value {
			const untyped_value = input orelse {
				if (self.required) {
					try context.add(v.required);
				}
				return asJsonValue(try self.executeFunction(null, context));
			};

			const value = switch (untyped_value) {
				.string => |s| s,
				else => {
					try context.add(INVALID_TYPE);
					return null;
				}
			};

			return asJsonValue(try self.validateNonNullString(value, context));
		}

		pub fn validateString(self: *const Self, optional_value: ?[]const u8, context: *Context(S)) !?[]const u8 {
			const value = optional_value orelse {
				if (self.required) {
					try context.add(v.required);
				}
				return null;
			};
			return self.validateNonNullString(value, context);
		}

		pub fn validateNonNullString(self: *const Self, value: []const u8, context: *Context(S)) !?[]const u8 {
			if (self.min) |m| {
				std.debug.assert(self.invalid_min != null);
				if (value.len < m) {
					try context.add(self.invalid_min.?);
					return null;
				}
			}

			if (self.max) |m| {
				std.debug.assert(self.invalid_max != null);
				if (value.len > m) {
					try context.add(self.invalid_max.?);
					return null;
				}
			}

			if (self.regex) |regex| {
				const valueZ = try context.allocator.dupeZ(u8, value);
				if (!re.isMatch(regex, valueZ)) {
					try context.add(self.invalid_pattern.?);
					return null;
				}
			}

			choice_blk: {
				if (self.choices) |choices| {
					std.debug.assert(self.invalid_choices != null);
					for (choices) |choice| {
						if (std.mem.eql(u8, choice, value)) break :choice_blk;
					}
					try context.add(self.invalid_choices.?);
					return null;
				}
			}
			return self.executeFunction(value, context);
		}

		fn executeFunction(self: *const Self, value: ?[]const u8, context: *Context(S)) !?[]const u8 {
			if (self.function) |f| {
				return f(value, context);
			}
			return null;
		}

		fn asJsonValue(optional_value: ?[]const u8) ?json.Value {
			if (optional_value) |value| return .{.string = value};
			return null;
		}
	};
}

fn allocateRegex(allocator: Allocator, pattern: []const u8) !*re.regex_t {
	if (pattern.len > 254) {
		return error.PatternTooLong;
	}

	var pattern_buffer: [255:0]u8 = undefined;
	std.mem.copy(u8, &pattern_buffer, pattern);
	pattern_buffer[pattern.len] = 0;

	const bufferZ = pattern_buffer;
	var slice = try allocator.alignedAlloc(u8, REGEX_T_ALIGNOF, REGEX_T_SIZEOF);
	const regex = @ptrCast(*re.regex_t, slice.ptr);

	if (re.regcomp(regex, &bufferZ, re.REG_EXTENDED | re.REG_NOSUB) != 0) {
		return error.InvalidPattern;
	}
	return regex;
}

const nullJson = @as(?json.Value, null);
test "string: required" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 1}, {});
	defer context.deinit(t.allocator);

	var builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const notRequired = builder.string(.{.required = false, });
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
		const validator = builder.string(.{.required = false});
		try t.expectEqual(nullJson, try validator.validateJsonValue(null, &context));
		try t.expectEqual(true, context.isValid());
	}
}

test "string: type" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 1}, {});
	defer context.deinit(t.allocator);

	var builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const validator = builder.string(.{});
	try t.expectEqual(nullJson, try validator.validateJsonValue(.{.integer = 33}, &context));
	try t.expectInvalid(.{.code = codes.TYPE_STRING}, context);
}

test "string: min length" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 1}, {});
	defer context.deinit(t.allocator);

	var builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const validator = builder.string(.{.min = 4});
	{
		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.string = "abc"}, &context));
		try t.expectInvalid(.{.code = codes.STRING_LEN_MIN, .data_min = 4, .err = "must have at least 4 characters"}, context);
	}

	{
		t.reset(&context);
		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.string = "abcd"}, &context));
		try t.expectEqual(true, context.isValid());
	}

	{
		t.reset(&context);
		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.string = "abcde"}, &context));
		try t.expectEqual(true, context.isValid());
	}

	const singular = builder.string(.{.min = 1});
	{
		try t.expectEqual(nullJson, try singular.validateJsonValue(.{.string = ""}, &context));
		try t.expectInvalid(.{.code = codes.STRING_LEN_MIN, .data_min = 1, .err = "must have at least 1 character"}, context);
	}
}

test "string: max length" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 1}, {});
	defer context.deinit(t.allocator);

	var builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const validator = builder.string(.{.max = 4});

	{
		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.string = "abcde"}, &context));
		try t.expectInvalid(.{.code = codes.STRING_LEN_MAX, .data_max = 4, .err = "must have no more than 4 characters"}, context);
	}

	{
		t.reset(&context);
		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.string = "abcd"}, &context));
		try t.expectEqual(true, context.isValid());
	}

	{
		t.reset(&context);
		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.string = "abc"}, &context));
		try t.expectEqual(true, context.isValid());
	}

	const singular = builder.string(.{.max = 1});
	{
		try t.expectEqual(nullJson, try singular.validateJsonValue(.{.string = "123"}, &context));
		try t.expectInvalid(.{.code = codes.STRING_LEN_MAX, .data_max = 1, .err = "must have no more than 1 character"}, context);
	}
}

test "string: choices" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 1}, {});
	defer context.deinit(t.allocator);

	var builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const validator = builder.string(.{.choices = &.{"one", "two", "three"}});

	{
		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.string = "nope"}, &context));
		try t.expectInvalid(.{.code = codes.STRING_CHOICE}, context);


		{
			t.reset(&context);
			try t.expectEqual(nullJson, try validator.validateJsonValue(.{.string = "two"}, &context));
			try t.expectEqual(true, context.isValid());
		}
		{
			t.reset(&context);
			try t.expectEqual(nullJson, try validator.validateJsonValue(.{.string = "three"}, &context));
			try t.expectEqual(true, context.isValid());
		}

		{
			t.reset(&context);
			try t.expectEqual(nullJson, try validator.validateJsonValue(.{.string = "one"}, &context));
			try t.expectEqual(true, context.isValid());
		}
	}

	var validator2: *String(void) = undefined;
	{
		var c1 = try t.allocator.alloc(u8, 5);
		std.mem.copy(u8, c1, "hello");

		var c2 = try t.allocator.alloc(u8, 3);
		std.mem.copy(u8, c2, "you");

		var choices2 = try t.allocator.alloc([]u8, 2);
		choices2[0] = c1;
		choices2[1] = c2;

		validator2 = builder.string(.{.choices = choices2});
		defer t.allocator.free(c1);
		defer t.allocator.free(c2);
		defer t.allocator.free(choices2);
	}

	{
		t.reset(&context);
		try t.expectEqual(nullJson, try validator2.validateJsonValue(.{.string = "nope"}, &context));
		try t.expectInvalid(.{.code = codes.STRING_CHOICE}, context);
	}

	t.reset(&context);
	try t.expectEqual(nullJson, try validator2.validateJsonValue(.{.string = "hello"}, &context));
	try t.expectEqual(true, context.isValid());
}

test "string: function" {
	var context = try Context(i64).init(t.allocator, .{.max_errors = 2, .max_nesting = 1}, 101);
	defer context.deinit(t.allocator);

	var builder = try Builder(i64).init(t.allocator);
	defer builder.deinit(t.allocator);

	const validator = builder.string(.{.function = testStringValidator});

	{
		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.string = "ok"}, &context));
		try t.expectEqual(true, context.isValid());
	}

	{
		try t.expectString("is-null", (try validator.validateJsonValue(null, &context)).?.string);
		try t.expectEqual(true, context.isValid());
	}

	{
		t.reset(&context);
		try t.expectString("19", (try validator.validateJsonValue(.{.string = "change"}, &context)).?.string);
		try t.expectEqual(true, context.isValid());
	}

	{
		t.reset(&context);
		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.string = "fail"}, &context));
		try t.expectInvalid(.{.code = 999, .err = "string validation error"}, context);
	}
}

test "string: pattern" {
	var context = try Context(void).init(t.allocator, .{.max_errors = 2, .max_nesting = 1}, {});
	defer context.deinit(t.allocator);

	var builder = try Builder(void).init(t.allocator);
	defer builder.deinit(t.allocator);

	const validator = builder.string(.{.pattern = "[ab]c"});

	{
		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.string = "ac"}, &context));
		try t.expectEqual(true, context.isValid());

		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.string = "bc"}, &context));
		try t.expectEqual(true, context.isValid());
	}

	{
		t.reset(&context);
		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.string = "AZ"}, &context));
		try t.expectInvalid(.{.code = codes.STRING_PATTERN, .data_pattern = "[ab]c"}, context);
	}

	{
		t.reset(&context);
		try t.expectEqual(nullJson, try validator.validateJsonValue(.{.string = "Ac"}, &context));
		try t.expectInvalid(.{.code = codes.STRING_PATTERN, .data_pattern = "[ab]c"}, context);
	}
}

fn testStringValidator(value: ?[]const u8, context: *Context(i64)) !?[]const u8 {
	std.debug.assert(context.state == 101);

	const s = value orelse return "is-null";

	if (std.mem.eql(u8, s, "change")) {
		// test the arena allocator while we're here
		var alt = try context.allocator.alloc(u8, 2);
		alt[0] = '1';
		alt[1] = '9';
		return alt;
	}

	if (std.mem.eql(u8, s, "fail")) {
		try context.add(v.Invalid{
			.code = 999,
			.err = "string validation error",
		});
		return null;
	}

	return null;
}


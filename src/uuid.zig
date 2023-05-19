const std = @import("std");
const typed = @import("typed");

const v = @import("validate.zig");
const codes = @import("codes.zig");
const Builder = @import("builder.zig").Builder;
const Context = @import("context.zig").Context;
const Validator = @import("validator.zig").Validator;

const ascii = std.ascii;
const Allocator = std.mem.Allocator;

const INVALID_TYPE = v.Invalid{
	.code = codes.TYPE_UUID,
	.err = "must be a UUID",
};

const encoded_pos = [16]u8{ 0, 2, 4, 6, 9, 11, 14, 16, 19, 21, 24, 26, 28, 30, 32, 34 };

// Hex to nibble mapping.
const hex_to_nibble = [256]u8{
	0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
	0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
	0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
	0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
	0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
	0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
	0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
	0x08, 0x09, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
	0xff, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0xff,
	0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
	0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
	0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
	0xff, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0xff,
	0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
	0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
	0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
	0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
	0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
	0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
	0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
	0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
	0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
	0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
	0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
	0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
	0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
	0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
	0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
	0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
	0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
	0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
	0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
};

pub fn UUID(comptime S: type) type {
	return struct {
		required: bool,
		function: ?*const fn(value: ?[]const u8, context: *Context(S)) anyerror!?[]const u8,
		const Self = @This();

		pub const Config = struct {
			required: bool = false,
			function: ?*const fn(value: ?[]const u8, context: *Context(S)) anyerror!?[]const u8 = null,
		};

		pub fn init(_: Allocator, config: Config) !Self {
			return .{
				.required = config.required,
				.function = config.function,
			};
		}

		pub fn validator(self: *Self) Validator(S) {
			return Validator(S).init(self);
		}

		pub fn trySetRequired(self: *Self, req: bool, builder: *Builder(S)) !*UUID(S) {
			var clone = try builder.allocator.create(UUID(S));
			clone.* = self.*;
			clone.required = req;
			return clone;
		}
		pub fn setRequired(self: *Self, req: bool, builder: *Builder(S)) *UUID(S) {
			return self.trySetRequired(req, builder) catch unreachable;
		}

		// part of the Validator interface, but noop for UUID
		pub fn nestField(_: *Self, _: Allocator, _: *v.Field) !void {}

		pub fn validateValue(self: *const Self, input: ?typed.Value, context: *Context(S)) !typed.Value {
			var string_value: ?[]const u8 = null;
			if (input) |untyped_value| {
				string_value = switch (untyped_value) {
					.string => |s| s,
					else => {
						try context.add(INVALID_TYPE);
						return .{.null = {}};
					}
				};
			}

			if (try self.validate(string_value, context)) |value| {
				return .{.string = value};
			}
			return .{.null = {}};
		}

		pub fn validate(self: *const Self, optional_value: ?[]const u8, context: *Context(S)) !?[]const u8 {
			const value = optional_value orelse {
				if (self.required) {
					try context.add(v.required);
					return null;
				}
				return self.executeFunction(null, context);
			};

			if (value.len != 36 or value[8] != '-' or value[13] != '-' or value[18] != '-' or value[23] != '-') {
				try context.add(INVALID_TYPE);
				return null;
			}

			inline for (encoded_pos) |i| {
				if (hex_to_nibble[value[i]] == 0xff) {
					try context.add(INVALID_TYPE);
					return null;
				}
				if (hex_to_nibble[value[i + 1]] == 0xff) {
					try context.add(INVALID_TYPE);
					return null;
				}
			}
			return self.executeFunction(value, context);
		}

		fn executeFunction(self: *const Self, value: ?[]const u8, context: *Context(S)) !?[]const u8 {
			if (self.function) |f| {
				return f(value, context);
			}
			return value;
		}
	};
}

const t = @import("t.zig");
const nullValue = typed.Value{.null = {}};
test "UUID: required" {
	var context = t.context();
	defer context.deinit(t.allocator);

	var builder = t.builder();
	defer builder.deinit(t.allocator);

	const notRequired = builder.uuid(.{.required = false, });
	const required = notRequired.setRequired(true, &builder);

	{
		try t.expectEqual(nullValue, try required.validateValue(null, &context));
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
		const validator = builder.uuid(.{.required = false});
		try t.expectEqual(nullValue, try validator.validateValue(null, &context));
		try t.expectEqual(true, context.isValid());
	}
}

test "UUID: type" {
	var context = t.context();
	defer context.deinit(t.allocator);

	var builder = t.builder();
	defer builder.deinit(t.allocator);

	const validator = builder.uuid(.{});
	try t.expectEqual(nullValue, try validator.validateValue(.{.i64 = 33}, &context));
	try t.expectInvalid(.{.code = codes.TYPE_UUID}, context);
}

test "UUID: uuid" {
	var context = t.context();
	defer context.deinit(t.allocator);

	var builder = t.builder();
	defer builder.deinit(t.allocator);

	const validator = builder.uuid(.{});

	{
		// valid
		const valids = [_][]const u8{
			"00000000-0000-0000-0000-000000000000",
			"FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF",
			"ffffffff-ffff-ffff-ffff-ffffffffffff",
			"4FBA5021-950F-4D7D-96A2-790B2D890080",
			"4fba5021-950f-4d7d-96a2-790b2d890080",
			"01234567-89AB-CDEF-abcd-ef1234567890",
		};
		for (valids) |valid| {
			try t.expectEqual(typed.Value{.string = valid}, try validator.validateValue(.{.string = valid}, &context));
			try t.expectEqual(true, context.isValid());
		}
	}

	{
		// empty
		t.reset(&context);
		try t.expectEqual(nullValue, try validator.validateValue(.{.string = ""}, &context));
		try t.expectInvalid(.{.code = codes.TYPE_UUID}, context);
	}

	{
		const invalids = [_][]const u8{
			"00000000-0000-0000-0000-00000000000",   // TOO SHORT
			"FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFFF", // TOO LONG
			"ffffffff-ffff-ffff-ffff-fffffffffffG", // invalid letter (end)
			"ZFBA5021-950F-4D7D-96A2-790B2D890080", // invalid letter (start)
			"4fba5021-950f-4d-d-96a2-790b2d890080", // invalid letter (middle)
			"0123456-789AB-CDEF-abcd-ef1234567890", // 1st dash if off
			"0123456-789ABC-DEF-abcd-ef1234567890", // 2nd dash if off
			"0123456-789AB-CDE-Fabcd-ef1234567890", // 3rd dash if off
			"0123456-789AB-CDEF-abc-def1234567890", // 4th dash if off
		};
		for (invalids) |invalid| {
			try t.expectEqual(nullValue, try validator.validateValue(.{.string = invalid}, &context));
			try t.expectInvalid(.{.code = codes.TYPE_UUID}, context);
		}
	}
}

test "UUID: function" {
	var context = t.context();
	defer context.deinit(t.allocator);

	var builder = t.builder();
	defer builder.deinit(t.allocator);

	const validator = builder.uuid(.{.function = testUUIDValidator});

	{
		try t.expectEqual(nullValue, try validator.validateValue(.{.string = "5111DC00-3b3E-445E-BA29-80B46F73D828"}, &context));
		try t.expectEqual(true, context.isValid());
	}

	{
		try t.expectEqual(typed.Value{.string = "is-null"}, (try validator.validateValue(null, &context)));
		try t.expectEqual(true, context.isValid());
	}

	{
		t.reset(&context);
		try t.expectString("FFFFFFFF-FFFF-0000-FFFF-FFFFFFFFFFFF", (try validator.validateValue(.{.string = "00000000-0000-0000-0000-000000000000"}, &context)).string);
		try t.expectEqual(true, context.isValid());
	}

	{
		t.reset(&context);
		try t.expectEqual(nullValue, try validator.validateValue(.{.string = "ffffffff-ffff-ffff-ffff-ffffffffffff"}, &context));
		try t.expectInvalid(.{.code = 1010, .err = "uuid validation error"}, context);
	}
}

fn testUUIDValidator(value: ?[]const u8, context: *Context(void)) !?[]const u8 {
	const s = value orelse return "is-null";

	if (std.mem.eql(u8, s, "00000000-0000-0000-0000-000000000000")) {
		// test the arena allocator while we're here
		return "FFFFFFFF-FFFF-0000-FFFF-FFFFFFFFFFFF";
	}

	if (std.mem.eql(u8, s, "ffffffff-ffff-ffff-ffff-ffffffffffff")) {
		try context.add(v.Invalid{
			.code = 1010,
			.err = "uuid validation error",
		});
		return null;
	}

	return null;
}


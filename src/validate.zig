const std = @import("std");
const typed = @import("typed");

pub const Pool = @import("pool.zig").Pool;
pub const Config = @import("pool.zig").Config;
pub const Field = @import("object.zig").Field;
pub const Builder = @import("builder.zig").Builder;
pub const Context = @import("context.zig").Context;

pub const Any = @import("any.zig").Any;
pub const Int = @import("int.zig").Int;
pub const Bool = @import("bool.zig").Bool;
pub const UUID = @import("uuid.zig").UUID;
pub const Float = @import("float.zig").Float;
pub const Array = @import("array.zig").Array;
pub const String = @import("string.zig").String;
pub const Object = @import("object.zig").Object;
pub const codes = @import("codes.zig");
pub const testing = @import("testing.zig");

pub const Invalid = struct {
	code: i64,
	err: []const u8,
	data: ?InvalidData = null,
};

pub const InvalidField = struct {
	field: ?[]const u8,
	code: i64,
	err: []const u8,
	data: ?InvalidData,
};

pub const InvalidDataType = enum {
	imin,
	imax,
	fmin,
	fmax,
	choice,
	pattern,
	details,
	generic,
};

pub const InvalidData = union(InvalidDataType) {
	imin: MinInt,
	imax: MaxInt,
	fmin: MinFloat,
	fmax: MaxFloat,
	choice: Choice,
	pattern: Pattern,
	details: Details, // generic string to be used by applications
	generic: std.json.Value, // generic, anything that std.json.Value can represent

	pub fn jsonStringify(self: InvalidData, options: std.json.StringifyOptions, out: anytype) !void {
		switch (self) {
			inline else => |v| return std.json.stringify(v, options, out),
		}
	}

	pub const MinInt = struct {
		min: i64
	};

	pub const MaxInt = struct {
		max: i64
	};

	pub const MinFloat = struct {
		min: f64
	};

	pub const MaxFloat = struct {
		max: f64
	};

	pub const Choice = struct {
		valid: []const []const u8,
	};

	pub const Pattern = struct {
		pattern: []const u8,
	};

	pub const Details = struct {
		details: []const u8,
	};
};

pub const required = Invalid{
	.code = codes.REQUIRED,
	.err = "is required",
};

pub fn simpleField(name: []const u8) Field {
	return .{
		.path = name,
		.name = name,
		.parts = null,
	};
}

test {
	std.testing.refAllDecls(@This());
}

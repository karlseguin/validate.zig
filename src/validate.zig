const std = @import("std");
const typed = @import("typed");

pub const Pool = @import("pool.zig").Pool;
pub const Config = @import("pool.zig").Config;
pub const Field = @import("object.zig").Field;
pub const Builder = @import("builder.zig").Builder;
pub const Context = @import("context.zig").Context;
pub const Validator = @import("validator.zig").Validator;
pub const DataBuilder = @import("data_builder.zig").DataBuilder;

pub const Any = @import("any.zig").Any;
pub const Int = @import("int.zig").Int;
pub const Bool = @import("bool.zig").Bool;
pub const Date = @import("date.zig").Date;
pub const Time = @import("time.zig").Time;
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
	data: ?typed.Value = null,
};

pub const InvalidField = struct {
	field: ?[]const u8,
	code: i64,
	err: []const u8,
	data: ?typed.Value = null,
};

pub const required = Invalid{
	.code = codes.REQUIRED,
	.err = "required",
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

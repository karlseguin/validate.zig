const codes = @import("codes.zig");
const object_validator = @import("object.zig");
const string_validator = @import("string.zig");

const Validator = @import("validator.zig").Validator;

pub const object = object_validator.object;
pub const string = string_validator.string;

pub const Field = object_validator.Field;
pub const Context = @import("context.zig").Context;

pub fn field(comptime S: type, name: []const u8, validator: Validator(S)) Field(S) {
	return .{
		.name = name,
		.validator = validator,
	};
}

pub const Invalid = struct {
	code: i64,
	err: []const u8,
	data: ?InvalidData = null,
};

pub const InvalidDataType = enum {
	imin,
	imax,
};

pub const InvalidData = union(InvalidDataType) {
	imin: MinInt,
	imax: MaxInt,

	pub const MinInt = struct {
		min: i64
	};

	pub const MaxInt = struct {
		max: i64
	};
};

pub const required = Invalid{
	.code = codes.REQUIRED,
	.err = "is required",
};

test {
	const std = @import("std");
	std.testing.refAllDecls(@This());
}

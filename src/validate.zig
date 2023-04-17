const codes = @import("codes.zig");
const o = @import("object.zig");
const s = @import("string.zig");

const Validator = @import("validator.zig").Validator;

pub const object = o.object;
pub const string = s.string;
pub const FieldS = o.FieldS;
pub const Field = FieldS(void);

pub fn fieldS(comptime S: type, name: []const u8, validator: Validator(S)) FieldS(S) {
	return .{
		.name = name,
		.validator = validator,
	};
}

pub fn field(name: []const u8, validator: Validator(void)) Field {
	return fieldS(void, name, validator);
}

pub const Invalid = struct {
	code: i64,
	@"error": []const u8,
	data: ?InvalidData = null,
};

pub const InvalidDataType = enum {
	min,
	max,
};

pub const InvalidData = union(InvalidDataType) {
	min: Min,
	max: Max,

	pub const Min = struct {
		min: i64
	};

	pub const Max = struct {
		max: i64
	};
};

pub const required = Invalid{
	.code = codes.REQUIRED,
	.@"error" = "is required",
};

test {
	const std = @import("std");
	std.testing.refAllDecls(@This());
}

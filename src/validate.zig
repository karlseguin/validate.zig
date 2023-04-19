const codes = @import("codes.zig");

pub const Field = @import("object.zig").Field;
pub const Builder = @import("builder.zig").Builder;

pub const Invalid = struct {
	code: i64,
	err: []const u8,
	data: ?InvalidData = null,
};

pub const InvalidDataType = enum {
	imin,
	imax,
	fmin,
	fmax,
	choice,
};

pub const InvalidData = union(InvalidDataType) {
	imin: MinInt,
	imax: MaxInt,
	fmin: MinFloat,
	fmax: MaxFloat,
	choice: Choice,

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
		valid: [][]const u8,
	};
};

pub const required = Invalid{
	.code = codes.REQUIRED,
	.err = "is required",
};

test {
	const std = @import("std");
	std.testing.refAllDecls(@This());
	_ = @import("object.zig");
	_ = @import("array.zig");
}

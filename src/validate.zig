const codes = @import("codes.zig");

pub const Builder = @import("builder.zig").Builder;

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
	_ = @import("object.zig");
}

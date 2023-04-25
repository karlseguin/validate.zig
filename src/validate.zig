const std = @import("std");
const codes = @import("codes.zig");

pub const Pool = @import("pool.zig").Pool;
pub const Config = @import("pool.zig").Config;
pub const Field = @import("object.zig").Field;
pub const Builder = @import("builder.zig").Builder;
pub const Context = @import("context.zig").Context;

pub const Any = @import("any.zig").Any;
pub const Int = @import("int.zig").Int;
pub const Bool = @import("bool.zig").Bool;
pub const Float = @import("float.zig").Float;
pub const Array = @import("array.zig").Array;
pub const Typed = @import("typed.zig").Typed;
pub const String = @import("string.zig").String;
pub const Object = @import("object.zig").Object;

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
	pattern,
};

pub const InvalidData = union(InvalidDataType) {
	imin: MinInt,
	imax: MaxInt,
	fmin: MinFloat,
	fmax: MaxFloat,
	choice: Choice,
	pattern: Pattern,

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
};

pub const required = Invalid{
	.code = codes.REQUIRED,
	.err = "is required",
};

pub const empty = Typed{.root = std.json.ObjectMap.init(undefined)};

test {
	std.testing.refAllDecls(@This());
}

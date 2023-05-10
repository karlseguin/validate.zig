const std = @import("std");
const testing = @import("testing.zig");

pub const expect = std.testing.expect;
pub const allocator = std.testing.allocator;

pub const expectEqual = std.testing.expectEqual;
pub const expectError = std.testing.expectError;
pub const expectString = std.testing.expectEqualStrings;

pub fn reset(context: anytype) void {
	var c = context;
	c.field = null;
	c._error_len = 0;
	c._nesting_idx = null;
}

pub const expectInvalid = testing.expectInvalid;
pub const expectInvalidErrors = testing.expectInvalidErrors;

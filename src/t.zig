const std = @import("std");
const testing = @import("testing.zig");

const Builder = @import("builder.zig").Builder;
const Context = @import("context.zig").Context;

pub const expect = std.testing.expect;
pub const allocator = std.testing.allocator;

pub const expectEqual = std.testing.expectEqual;
pub const expectError = std.testing.expectError;
pub const expectString = std.testing.expectEqualStrings;

pub fn reset(ctx: anytype) void {
    var c = ctx;
    c.field = null;
    c._error_len = 0;
    c._nesting_idx = null;
}

pub const expectInvalid = testing.expectInvalid;

pub fn context() Context(void) {
    return Context(void).init(allocator, .{ .max_errors = 2, .max_nesting = 1 }, {}) catch unreachable;
}

pub fn builder() Builder(void) {
    return Builder(void).init(allocator) catch unreachable;
}

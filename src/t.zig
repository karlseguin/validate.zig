const std = @import("std");
const validate = @import("validate.zig");

pub const allocator = std.testing.allocator;
pub const expectEqual = std.testing.expectEqual;
pub const expectError = std.testing.expectError;
pub const expectString = std.testing.expectEqualStrings;

pub fn assertErrors(v: anytype, expected: []const validate.Error) !void {
    try expectEqual(expected.len, v.len);
    for (expected, v._errors[0..v.len]) |e, a| {
        try expectString(e.field, a.field);
        try expectEqual(e.code, a.code);
        try expectString(e.label, a.label);

        const expected_data = try std.json.stringifyAlloc(allocator, e.data, .{});
        defer allocator.free(expected_data);

        const actual_data = try std.json.stringifyAlloc(allocator, a.data, .{});
        defer allocator.free(actual_data);

        try expectString(expected_data, actual_data);
    }
}

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

var _arena: ?ArenaAllocator = null;
var pool: ?*validate.Validators(void) = null;

pub fn reset() void {
    if (pool) |p| {
        p.deinit();
        pool = null;
    }
    if (_arena) |a| {
        a.deinit();
        _arena = null;
    }
}

pub fn validator() *validate.Validator(void) {
    if (pool == null) {
        pool = validate.Validators(void).init(allocator, .{.count = 1}) catch unreachable;
    }
    return pool.?.acquire(.en) catch unreachable;
}

pub fn arena() Allocator {
    if (_arena == null)  {
        _arena = ArenaAllocator.init(allocator);
    }
    return _arena.?.allocator();
}

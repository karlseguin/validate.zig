const std = @import("std");
const v = @import("validate.zig");

const M = @This();

pub fn minLength(value: []const u8, min: usize) bool {
    return value.len >= min;
}

pub fn maxLength(value: []const u8, max: usize) bool {
    return value.len <= max;
}

pub fn Validator(comptime V: type) type {
    return struct {
        value: []const u8,
        field_name: []const u8,
        _validator: *V,

        const Self = @This();

        pub fn init(validator: *V, field_name: []const u8, value: []const u8) Self {
            return .{
                .value = value,
                .field_name = field_name,
                ._validator = validator,
            };
        }

        pub fn trim(self: *const Self) void {
            // OMG, what?!
            @constCast(self).value = std.mem.trimRight(u8, self.value, &std.ascii.whitespace);
        }

        pub fn minLength(self: *const Self, min: usize) bool {
            if (M.minLength(self.value, min) == true) {
                return true;
            }
            self.invalid(.string_len_min, .{.min = min});
            return false;
        }

        pub fn maxLength(self: *const Self, max: usize) bool {
            if (M.maxLength(self.value, max) == true) {
                return true;
            }
            self.invalid(.string_len_max, .{.max = max});
            return false;
        }

        pub fn length(self: *const Self, min: usize, max: usize) bool {
            if (min == 0) {
                return self.maxLength(max);
            }
            const value = self.value;
            if (M.minLength(value, min) and M.maxLength(value, max)) {
                return true;
            }
            self.invalid(.string_len, .{.min = min, .max = max});
            return false;
        }

        pub fn invalid(self: *const Self, code: V.Code, data: anytype) void {
            self._validator.invalid(self.field_name, code, data);
        }
    };
}

pub fn isString(comptime T: type) bool {
    return comptime blk: {
        // Only pointer types can be strings, no optionals
        const info = @typeInfo(T);
        if (info != .pointer) break :blk false;

        const ptr = &info.pointer;
        // Check for CV qualifiers that would prevent coerction to []const u8
        if (ptr.is_volatile or ptr.is_allowzero) break :blk false;

        // If it's already a slice, simple check.
        if (ptr.size == .Slice) {
            break :blk ptr.child == u8;
        }

        // Otherwise check if it's an array type that coerces to slice.
        if (ptr.size == .One) {
            const child = @typeInfo(ptr.child);
            if (child == .array) {
                const arr = &child.array;
                break :blk arr.child == u8;
            }
        }

        break :blk false;
    };
}

const t = @import("t.zig");
test "string:minLength" {
    try t.expectEqual(true, minLength("", 0));
    try t.expectEqual(true, minLength("1", 0));
    try t.expectEqual(true, minLength("a", 1));
    try t.expectEqual(true, minLength("ab", 1));
    try t.expectEqual(true, minLength("a" ** 10, 10));
    try t.expectEqual(true, minLength("a" ** 11, 10));

    try t.expectEqual(false, minLength("", 1));
    try t.expectEqual(false, minLength("", 2));
    try t.expectEqual(false, minLength("1", 2));
    try t.expectEqual(false, minLength("a" ** 9, 10));
}

test "string:maxLength" {
    try t.expectEqual(true, maxLength("", 0));
    try t.expectEqual(true, maxLength("a", 1));
    try t.expectEqual(true, maxLength("", 1));
    try t.expectEqual(true, maxLength("1", 2));
    try t.expectEqual(true, maxLength("a" ** 10, 10));
    try t.expectEqual(true, maxLength("a" ** 9, 10));
    try t.expectEqual(true, maxLength("a" ** 8, 10));

    try t.expectEqual(false, maxLength("1", 0));
    try t.expectEqual(false, maxLength("12", 1));
    try t.expectEqual(false, maxLength("12345", 1));
    try t.expectEqual(false, maxLength("a" ** 10, 9));
    try t.expectEqual(false, maxLength("a" ** 10, 8));
}

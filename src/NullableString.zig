const std = @import("std");
const v = @import("validate.zig");

const String = @import("String.zig");

pub fn Validator(comptime V: type) type {
    return struct {
        value: ?[]const u8,
        _nested: ?String.Validator(V),

        const Self = @This();

        pub fn init(validator: *V, field_name: []const u8, value: ?[]const u8) Self {
            return .{
                .value = value,
                ._nested = if (value) |str| String.Validator(V).init(validator, field_name, str) else null,
            };
        }

        pub fn trim(self: *const Self) void {
            if (self._nested) |sv| {
                sv.trim();
            }
        }

        pub fn minLength(self: *const Self, min: usize) bool {
            if (self._nested) |sv| {
                return sv.minLength(min);
            }
            return true;
        }

        pub fn maxLength(self: *const Self, max: usize) bool {
            if (self._nested) |sv| {
                return sv.maxLength(max);
            }
            return true;
        }

        pub fn length(self: *const Self, min: usize, max: usize) bool {
            if (self._nested) |sv| {
                return sv.length(min, max);
            }
            return true;
        }
    };
}

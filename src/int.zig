const std = @import("std");
const v = @import("validate.zig");

const M = @This();

pub fn atLeast(value: i64, min: i64) bool {
    return value >= min;
}

pub fn atMost(value: i64, max: i64) bool {
    return value <= max;
}

pub fn Validator(comptime V: type) type {
    return struct {
        value: i64,
        field_name: []const u8,
        _validator: *V,

        const Self = @This();

        pub fn init(validator: *V, field_name: []const u8, value: i64) Self {
            return .{
                .value = value,
                .field_name = field_name,
                ._validator = validator,
            };
        }

        pub fn atLeast(self: *const Self, min: i64) bool {
            if (M.atLeast(self.value, min) == true) {
                return true;
            }
            self.invalid(.int_min, .{.min = min});
            return false;
        }

        pub fn atMost(self: *const Self, max: i64) bool {
            if (M.atMost(self.value, max) == true) {
                return true;
            }
            self.invalid(.int_max, .{.max = max});
            return false;
        }

        pub fn range(self: *const Self, min: i64, max: i64) bool {
            if (M.atLeast(self.value, min) and M.atMost(self.value, max)) {
                return true;
            }
            self.invalid(.int_range, .{.min = min, .max = max});
        }

        pub fn invalid(self: *const Self, code: V.Code, data: anytype) void {
            self._validator.invalid(self.field_name, code, data);
        }
    };
}

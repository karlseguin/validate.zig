const std = @import("std");
const v = @import("validate.zig");


pub fn Validator(comptime V: type) type {
    return struct {
        value: bool,
        field_name: []const u8,
        _validator: *V,

        const Self = @This();

        pub fn init(validator: *V, field_name: []const u8, value: bool) Self {
            return .{
                .value = value,
                .field_name = field_name,
                ._validator = validator,
            };
        }

        pub fn invalid(self: *const Self, code: V.Code, data: anytype) void {
            self._validator.invalid(self.field_name, code, data);
        }
    };
}

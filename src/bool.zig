const std = @import("std");
const typed = @import("typed");
const v = @import("validate.zig");

const codes = v.codes;
const Builder = v.Builder;
const Context = v.Context;
const Validator = v.Validator;
const DataBuilder = v.DataBuilder;

const Allocator = std.mem.Allocator;

const INVALID_TYPE = v.Invalid{
    .code = codes.TYPE_BOOL,
    .err = "must be a bool",
};

pub fn Bool(comptime S: type) type {
    return struct {
        parse: bool,
        required: bool,
        default: ?bool,
        function: ?*const fn (value: ?bool, context: *Context(S)) anyerror!?bool,

        const Self = @This();

        pub const Config = struct {
            parse: bool = false,
            default: ?bool = null,
            required: bool = false,
            function: ?*const fn (value: ?bool, context: *Context(S)) anyerror!?bool = null,
        };

        pub fn init(_: Allocator, config: Config) !Self {
            return .{
                .parse = config.parse,
                .default = config.default,
                .required = config.required,
                .function = config.function,
            };
        }

        pub fn validator(self: *Self) Validator(S) {
            return Validator(S).init(self);
        }

        pub fn trySetRequired(self: *Self, req: bool, builder: *Builder(S)) !*Bool(S) {
            var clone = try builder.allocator.create(Bool(S));
            clone.* = self.*;
            clone.required = req;
            return clone;
        }
        pub fn setRequired(self: *Self, req: bool, builder: *Builder(S)) *Bool(S) {
            return self.trySetRequired(req, builder) catch unreachable;
        }

        // part of the Validator interface, but noop for bools
        pub fn nestField(_: *Self, _: Allocator, _: *v.Field) !void {}

        pub fn validateValue(self: *const Self, input: ?typed.Value, context: *Context(S)) !typed.Value {
            var bool_value: ?bool = null;
            if (input) |untyped_value| {
                var valid = false;
                switch (untyped_value) {
                    .bool => |b| {
                        bool_value = b;
                        valid = true;
                    },
                    .string => |s| blk: {
                        if (self.parse) {
                            bool_value = parseString(s) orelse break :blk;
                            valid = true;
                        }
                    },
                    else => {},
                }

                if (!valid) {
                    try context.add(INVALID_TYPE);
                    return .{ .null = {} };
                }
            }

            if (try self.validate(bool_value, context)) |value| {
                return .{ .bool = value };
            }
            return .{ .null = {} };
        }

        pub fn validateString(self: *const Self, input: ?[]const u8, context: *Context(S)) !?bool {
            var bool_value: ?bool = null;
            if (input) |string_value| {
                bool_value = parseString(string_value) orelse {
                    try context.add(INVALID_TYPE);
                    return null;
                };
            }
            return self.validate(bool_value, context);
        }

        pub fn validate(self: *const Self, optional_value: ?bool, context: *Context(S)) !?bool {
            const value = optional_value orelse {
                if (self.required) {
                    try context.add(v.required);
                    return null;
                }
                return self.executeFunction(null, context);
            };

            return self.executeFunction(value, context);
        }

        fn executeFunction(self: *const Self, value: ?bool, context: *Context(S)) !?bool {
            if (self.function) |f| {
                return (try f(value, context)) orelse self.default;
            }
            return value orelse self.default;
        }
    };
}

fn parseString(s: []const u8) ?bool {
    if (s.len == 1) {
        const a = s[0];
        if (a == '1') return true;
        if (a == 'T') return true;
        if (a == 't') return true;
        if (a == '0') return false;
        if (a == 'F') return false;
        if (a == 'f') return false;
    }
    if (std.ascii.eqlIgnoreCase(s, "true")) return true;
    if (std.ascii.eqlIgnoreCase(s, "false")) return false;
    return null;
}

const t = @import("t.zig");
const nullValue = typed.Value{ .null = {} };
test "bool: required" {
    var context = t.context();
    defer context.deinit(t.allocator);

    var builder = t.builder();
    defer builder.deinit(t.allocator);

    const not_required = builder.boolean(.{ .required = false });
    const required = not_required.setRequired(true, &builder);
    const not_required_default = builder.boolean(.{ .required = false, .default = true });

    {
        try t.expectEqual(@as(?bool, null), try required.validate(null, &context));
        try t.expectInvalid(.{ .code = codes.REQUIRED }, context);
    }

    {
        t.reset(&context);
        try t.expectEqual(nullValue, try not_required.validateValue(null, &context));
        try t.expectEqual(true, context.isValid());
    }

    {
        t.reset(&context);
        try t.expectEqual(true, (try not_required_default.validateValue(null, &context)).bool);
        try t.expectEqual(true, context.isValid());
    }

    {
        // test required = false when configured directly (not via setRequired)
        t.reset(&context);
        const validator = builder.boolean(.{ .required = false });
        try t.expectEqual(nullValue, try validator.validateValue(null, &context));
        try t.expectEqual(true, context.isValid());
    }
}

test "bool: type" {
    var context = t.context();
    defer context.deinit(t.allocator);

    var builder = t.builder();
    defer builder.deinit(t.allocator);

    const validator = builder.boolean(.{});
    {
        try t.expectEqual(nullValue, try validator.validateValue(.{ .string = "NOPE" }, &context));
        try t.expectInvalid(.{ .code = codes.TYPE_BOOL }, context);
    }

    {
        t.reset(&context);
        try t.expectEqual(true, (try validator.validateValue(.{ .bool = true }, &context)).bool);
        try t.expectEqual(true, context.isValid());
    }

    {
        t.reset(&context);
        try t.expectEqual(false, (try validator.validateValue(.{ .bool = false }, &context)).bool);
        try t.expectEqual(true, context.isValid());
    }
}

test "bool: parse" {
    var context = t.context();
    defer context.deinit(t.allocator);

    var builder = t.builder();
    defer builder.deinit(t.allocator);

    const validator = builder.boolean(.{ .parse = true });

    {
        // still works fine with correct type
        try t.expectEqual(true, (try validator.validateValue(.{ .bool = true }, &context)).bool);
        try t.expectEqual(true, context.isValid());
    }

    const true_strings = [_][]const u8{ "t", "T", "true", "True", "TRUE", "1" };
    for (true_strings) |value| {
        // parses a string and applies the validation on the parsed value
        t.reset(&context);
        try t.expectEqual(true, (try validator.validateValue(.{ .string = value }, &context)).bool);
        try t.expectEqual(true, context.isValid());
    }

    const false_strings = [_][]const u8{ "f", "F", "false", "False", "FALSE", "0" };
    for (false_strings) |value| {
        // parses a string and applies the validation on the parsed value
        t.reset(&context);
        try t.expectEqual(false, (try validator.validateValue(.{ .string = value }, &context)).bool);
        try t.expectEqual(true, context.isValid());
    }
}

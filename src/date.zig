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
    .code = codes.TYPE_DATE,
    .err = "must be a date",
};

pub fn Date(comptime S: type) type {
    return struct {
        required: bool,
        min: ?typed.Date,
        max: ?typed.Date,
        parse: bool,
        default: ?typed.Date,
        min_invalid: ?v.Invalid,
        max_invalid: ?v.Invalid,
        function: ?*const fn (value: ?typed.Date, context: *Context(S)) anyerror!?typed.Date,

        const Self = @This();

        pub const Config = struct {
            min: ?typed.Date = null,
            max: ?typed.Date = null,
            parse: bool = false,
            default: ?typed.Date = null,
            required: bool = false,
            function: ?*const fn (value: ?typed.Date, context: *Context(S)) anyerror!?typed.Date = null,
        };

        pub fn init(allocator: Allocator, config: Config) !Self {
            var min_invalid: ?v.Invalid = null;
            if (config.min) |m| {
                min_invalid = v.Invalid{
                    .code = codes.DATE_MIN,
                    .data = try DataBuilder.init(allocator).put("min", m).done(),
                    .err = try std.fmt.allocPrint(allocator, "cannot be before {d}", .{m}),
                };
            }

            var max_invalid: ?v.Invalid = null;
            if (config.max) |m| {
                max_invalid = v.Invalid{
                    .code = codes.DATE_MAX,
                    .data = try DataBuilder.init(allocator).put("max", m).done(),
                    .err = try std.fmt.allocPrint(allocator, "cannot be after {d}", .{m}),
                };
            }

            return .{
                .min = config.min,
                .max = config.max,
                .parse = config.parse,
                .default = config.default,
                .min_invalid = min_invalid,
                .max_invalid = max_invalid,
                .required = config.required,
                .function = config.function,
            };
        }

        pub fn validator(self: *Self) Validator(S) {
            return Validator(S).init(self);
        }

        pub fn trySetRequired(self: *Self, req: bool, builder: *Builder(S)) !*Date(S) {
            var clone = try builder.allocator.create(Date(S));
            clone.* = self.*;
            clone.required = req;
            return clone;
        }
        pub fn setRequired(self: *Self, req: bool, builder: *Builder(S)) *Date(S) {
            return self.trySetRequired(req, builder) catch unreachable;
        }

        // part of the Validator interface, but noop for dates
        pub fn nestField(_: *Self, _: Allocator, _: *v.Field) !void {}

        pub fn validateValue(self: *const Self, input: ?typed.Value, context: *Context(S)) !typed.Value {
            var date_value: ?typed.Date = null;
            if (input) |untyped_value| {
                var valid = false;
                switch (untyped_value) {
                    .date => |n| {
                        valid = true;
                        date_value = n;
                    },
                    .string => |s| blk: {
                        if (self.parse) {
                            date_value = typed.Date.parse(s, .iso8601) catch break :blk;
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

            if (try self.validate(date_value, context)) |value| {
                return typed.new(context.allocator, value);
            }
            return .{ .null = {} };
        }

        pub fn validateString(self: *const Self, input: ?[]const u8, context: *Context(S)) !?typed.Date {
            var date_value: ?typed.Date = null;
            if (input) |string_value| {
                date_value = typed.Date.parse(string_value, .iso8601) catch {
                    try context.add(INVALID_TYPE);
                    return null;
                };
            }
            return self.validate(date_value, context);
        }

        pub fn validate(self: *const Self, optional_value: ?typed.Date, context: *Context(S)) !?typed.Date {
            const value = optional_value orelse {
                if (self.required) {
                    try context.add(v.required);
                    return null;
                }
                return self.executeFunction(null, context);
            };

            if (self.min) |m| {
                if (value.order(m) == .lt) {
                    try context.add(self.min_invalid.?);
                    return null;
                }
            }

            if (self.max) |m| {
                if (value.order(m) == .gt) {
                    try context.add(self.max_invalid.?);
                    return null;
                }
            }

            return self.executeFunction(value, context);
        }

        fn executeFunction(self: *const Self, value: ?typed.Date, context: *Context(S)) !?typed.Date {
            if (self.function) |f| {
                return (try f(value, context)) orelse self.default;
            }
            return value orelse self.default;
        }
    };
}

const t = @import("t.zig");
const nullValue = typed.Value{ .null = {} };
test "date: required" {
    var context = try Context(void).init(t.allocator, .{ .max_errors = 2, .max_nesting = 1 }, {});
    defer context.deinit(t.allocator);

    var builder = try Builder(void).init(t.allocator);
    defer builder.deinit(t.allocator);

    const default = try typed.Date.parse("2023-05-24", .iso8601);
    const not_required = builder.date(.{
        .required = false,
    });
    const required = not_required.setRequired(true, &builder);
    const not_required_default = builder.date(.{ .required = false, .default = default });

    {
        try t.expectEqual(nullValue, try required.validateValue(null, &context));
        try t.expectInvalid(.{ .code = codes.REQUIRED }, context);
    }

    {
        t.reset(&context);
        try t.expectEqual(nullValue, try not_required.validateValue(null, &context));
        try t.expectEqual(true, context.isValid());
    }

    {
        t.reset(&context);
        try t.expectEqual(default, (try not_required_default.validateValue(null, &context)).date);
        try t.expectEqual(true, context.isValid());
    }

    {
        // test required = false when configured directly (not via setRequired)
        t.reset(&context);
        const validator = builder.date(.{ .required = false });
        try t.expectEqual(nullValue, try validator.validateValue(null, &context));
        try t.expectEqual(true, context.isValid());
    }
}

test "date: type" {
    var context = try Context(void).init(t.allocator, .{ .max_errors = 2, .max_nesting = 1 }, {});
    defer context.deinit(t.allocator);

    const builder = try Builder(void).init(t.allocator);
    defer builder.deinit(t.allocator);

    const validator = builder.date(.{});
    try t.expectEqual(nullValue, try validator.validateValue(.{ .string = "NOPE" }, &context));
    try t.expectInvalid(.{ .code = codes.TYPE_DATE }, context);
}

test "date: min" {
    var context = try Context(void).init(t.allocator, .{ .max_errors = 2, .max_nesting = 1 }, {});
    defer context.deinit(t.allocator);

    const builder = try Builder(void).init(t.allocator);
    defer builder.deinit(t.allocator);

    const validator = builder.date(.{ .min = try typed.Date.parse("2023-06-20", .iso8601) });
    {
        try t.expectEqual(nullValue, try validator.validateValue(.{ .date = try typed.Date.parse("2023-06-19", .iso8601) }, &context));
        try t.expectInvalid(.{ .code = codes.DATE_MIN, .data = .{ .min = "2023-06-20" } }, context);
    }

    {
        t.reset(&context);
        const d = try typed.Date.parse("2023-06-20", .iso8601);
        try t.expectEqual(typed.Value{ .date = d }, try validator.validateValue(.{ .date = d }, &context));
        try t.expectEqual(true, context.isValid());
    }

    {
        t.reset(&context);
        const d = try typed.Date.parse("2023-07-01", .iso8601);
        try t.expectEqual(typed.Value{ .date = d }, try validator.validateValue(.{ .date = d }, &context));
        try t.expectEqual(true, context.isValid());
    }
}

test "date: max" {
    var context = try Context(void).init(t.allocator, .{ .max_errors = 2, .max_nesting = 1 }, {});
    defer context.deinit(t.allocator);

    const builder = try Builder(void).init(t.allocator);
    defer builder.deinit(t.allocator);

    const validator = builder.date(.{ .max = try typed.Date.parse("2023-06-20", .iso8601) });

    {
        try t.expectEqual(nullValue, try validator.validateValue(.{ .date = try typed.Date.parse("2023-06-21", .iso8601) }, &context));
        try t.expectInvalid(.{ .code = codes.DATE_MAX, .data = .{ .max = "2023-06-20" } }, context);
    }

    {
        t.reset(&context);
        const d = try typed.Date.parse("2023-06-20", .iso8601);
        try t.expectEqual(typed.Value{ .date = d }, try validator.validateValue(.{ .date = d }, &context));
        try t.expectEqual(true, context.isValid());
    }

    {
        t.reset(&context);
        const d = try typed.Date.parse("2023-05-31", .iso8601);
        try t.expectEqual(typed.Value{ .date = d }, try validator.validateValue(.{ .date = d }, &context));
        try t.expectEqual(true, context.isValid());
    }
}

test "date: parse" {
    var context = try Context(void).init(t.allocator, .{ .max_errors = 2, .max_nesting = 1 }, {});
    defer context.deinit(t.allocator);

    const builder = try Builder(void).init(t.allocator);
    defer builder.deinit(t.allocator);

    const validator = builder.date(.{ .max = try typed.Date.parse("2023-06-20", .iso8601), .parse = true });

    {
        // still works fine with correct type
        try t.expectEqual(nullValue, try validator.validateValue(.{ .date = try typed.Date.parse("2023-06-21", .iso8601) }, &context));
        try t.expectInvalid(.{ .code = codes.DATE_MAX, .data = .{ .max = "2023-06-20" } }, context);
    }

    {
        // parses a string and applies the validation on the parsed value
        t.reset(&context);
        try t.expectEqual(nullValue, try validator.validateValue(.{ .string = "2023-06-22" }, &context));
        try t.expectInvalid(.{ .code = codes.DATE_MAX, .data = .{ .max = "2023-06-20" } }, context);
    }

    {
        // parses a string and returns the typed value
        t.reset(&context);
        try t.expectEqual(try typed.Date.parse("2023-06-20", .iso8601), (try validator.validateValue(.{ .string = "2023-06-20" }, &context)).date);
        try t.expectEqual(true, context.isValid());
    }
}

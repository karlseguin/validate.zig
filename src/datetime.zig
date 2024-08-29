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
    .code = codes.TYPE_DATETIME,
    .err = "must be a datetime",
};

pub fn DateTime(comptime S: type) type {
    return struct {
        required: bool,
        min: ?typed.DateTime,
        max: ?typed.DateTime,
        parse: ParseMode,
        default: ?typed.DateTime,
        min_invalid: ?v.Invalid,
        max_invalid: ?v.Invalid,
        function: ?*const fn (value: ?typed.DateTime, context: *Context(S)) anyerror!?typed.DateTime,

        const Self = @This();

        pub const ParseMode = packed struct(u32) {
            rfc3339: bool = false,
            timestamp_s: bool = false,
            timestamp_ms: bool = false,
            _padding: u29 = 0,
        };

        pub const Config = struct {
            min: ?typed.DateTime = null,
            max: ?typed.DateTime = null,
            parse: ParseMode = .{},
            default: ?typed.DateTime = null,
            required: bool = false,
            function: ?*const fn (value: ?typed.DateTime, context: *Context(S)) anyerror!?typed.DateTime = null,
        };

        pub fn init(allocator: Allocator, config: Config) !Self {
            var min_invalid: ?v.Invalid = null;
            if (config.min) |m| {
                min_invalid = v.Invalid{
                    .code = codes.DATETIME_MIN,
                    .data = try DataBuilder.init(allocator).put("min", m).done(),
                    .err = try std.fmt.allocPrint(allocator, "cannot be before {d}", .{m}),
                };
            }

            var max_invalid: ?v.Invalid = null;
            if (config.max) |m| {
                max_invalid = v.Invalid{
                    .code = codes.DATETIME_MAX,
                    .data = try DataBuilder.init(allocator).put("max", m).done(),
                    .err = try std.fmt.allocPrint(allocator, "cannot be after {d}", .{m}),
                };
            }

            if (config.parse.timestamp_s and config.parse.timestamp_ms) {
                return error.ConflictingPareConfig;
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

        pub fn trySetRequired(self: *Self, req: bool, builder: *Builder(S)) !*DateTime(S) {
            var clone = try builder.allocator.create(DateTime(S));
            clone.* = self.*;
            clone.required = req;
            return clone;
        }
        pub fn setRequired(self: *Self, req: bool, builder: *Builder(S)) *DateTime(S) {
            return self.trySetRequired(req, builder) catch unreachable;
        }

        // part of the Validator interface, but noop for dates
        pub fn nestField(_: *Self, _: Allocator, _: *v.Field) !void {}

        pub fn validateValue(self: *const Self, input: ?typed.Value, context: *Context(S)) !typed.Value {
            var datetime_value: ?typed.DateTime = null;
            if (input) |untyped_value| {
                var valid = false;
                switch (untyped_value) {
                    .datetime => |n| {
                        valid = true;
                        datetime_value = n;
                    },
                    .string => |s| blk: {
                        if (self.parse.rfc3339) {
                            datetime_value = typed.DateTime.parse(s, .rfc3339) catch break :blk;
                            valid = true;
                        }
                    },
                    .i64, .u32 => |n| blk: {
                        if (self.parse.timestamp_s) {
                            datetime_value = typed.DateTime.fromUnix(n, .seconds) catch break :blk;
                            valid = true;
                        } else if (self.parse.timestamp_ms) {
                            datetime_value = typed.DateTime.fromUnix(n, .milliseconds) catch break :blk;
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

            if (try self.validate(datetime_value, context)) |value| {
                return typed.new(context.allocator, value);
            }
            return .{ .null = {} };
        }

        pub fn validateString(self: *const Self, input: ?[]const u8, context: *Context(S)) !?typed.DateTime {
            var datetime_value: ?typed.DateTime = null;
            if (input) |string_value| {
                var valid = false;
                if (self.parse.rfc3339) blk: {
                    datetime_value = typed.DateTime.parse(string_value, .rfc3339) catch break :blk;
                    valid = true;
                }
                if (valid == false) {
                    if (self.parse.timestamp_s) blk: {
                        datetime_value = typed.DateTime.fromUnix(string_value, .seconds) catch break :blk;
                        valid = true;
                    } else if (self.parse.timestamp_ms) blk: {
                        datetime_value = typed.DateTime.fromUnix(string_value, .milliseconds) catch break :blk;
                        valid = true;
                    }
                }

                if (valid == false) {
                    try context.add(INVALID_TYPE);
                    return null;
                }
            }
            return self.validate(datetime_value, context);
        }

        pub fn validate(self: *const Self, optional_value: ?typed.DateTime, context: *Context(S)) !?typed.DateTime {
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

        fn executeFunction(self: *const Self, value: ?typed.DateTime, context: *Context(S)) !?typed.DateTime {
            if (self.function) |f| {
                return (try f(value, context)) orelse self.default;
            }
            return value orelse self.default;
        }
    };
}

const t = @import("t.zig");
const nullValue = typed.Value{ .null = {} };
test "datetime: required" {
    var context = try Context(void).init(t.allocator, .{ .max_errors = 2, .max_nesting = 1 }, {});
    defer context.deinit(t.allocator);

    var builder = try Builder(void).init(t.allocator);
    defer builder.deinit(t.allocator);

    const default = try typed.DateTime.parse("2023-05-24T02:33:58Z", .rfc3339);
    const not_required = builder.dateTime(.{
        .required = false,
    });
    const required = not_required.setRequired(true, &builder);
    const not_required_default = builder.dateTime(.{ .required = false, .default = default });

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
        try t.expectEqual(default, (try not_required_default.validateValue(null, &context)).datetime);
        try t.expectEqual(true, context.isValid());
    }

    {
        // test required = false when configured directly (not via setRequired)
        t.reset(&context);
        const validator = builder.dateTime(.{ .required = false });
        try t.expectEqual(nullValue, try validator.validateValue(null, &context));
        try t.expectEqual(true, context.isValid());
    }
}

test "datetime: type" {
    var context = try Context(void).init(t.allocator, .{ .max_errors = 2, .max_nesting = 1 }, {});
    defer context.deinit(t.allocator);

    const builder = try Builder(void).init(t.allocator);
    defer builder.deinit(t.allocator);

    const validator = builder.date(.{});
    try t.expectEqual(nullValue, try validator.validateValue(.{ .string = "NOPE" }, &context));
    try t.expectInvalid(.{ .code = codes.TYPE_DATE }, context);
}

test "datetime: min" {
    var context = try Context(void).init(t.allocator, .{ .max_errors = 2, .max_nesting = 1 }, {});
    defer context.deinit(t.allocator);

    const builder = try Builder(void).init(t.allocator);
    defer builder.deinit(t.allocator);

    const validator = builder.dateTime(.{ .min = try typed.DateTime.parse("2023-06-20T00:00:00Z", .rfc3339) });
    {
        try t.expectEqual(nullValue, try validator.validateValue(.{ .datetime = try typed.DateTime.parse("2023-06-19T00:00:00Z", .rfc3339) }, &context));
        try t.expectInvalid(.{ .code = codes.DATETIME_MIN, .data = .{ .min = "2023-06-20T00:00:00Z" } }, context);
    }

    {
        t.reset(&context);
        const d = try typed.DateTime.parse("2023-06-20T00:00:00Z", .rfc3339);
        try t.expectEqual(typed.Value{ .datetime = d }, try validator.validateValue(.{ .datetime = d }, &context));
        try t.expectEqual(true, context.isValid());
    }

    {
        t.reset(&context);
        const d = try typed.DateTime.parse("2023-07-01T00:00:00Z", .rfc3339);
        try t.expectEqual(typed.Value{ .datetime = d }, try validator.validateValue(.{ .datetime = d }, &context));
        try t.expectEqual(true, context.isValid());
    }
}

test "datetime: max" {
    var context = try Context(void).init(t.allocator, .{ .max_errors = 2, .max_nesting = 1 }, {});
    defer context.deinit(t.allocator);

    const builder = try Builder(void).init(t.allocator);
    defer builder.deinit(t.allocator);

    const validator = builder.dateTime(.{ .max = try typed.DateTime.parse("2023-06-20T00:00:00Z", .rfc3339) });

    {
        try t.expectEqual(nullValue, try validator.validateValue(.{ .datetime = try typed.DateTime.parse("2023-06-21T00:00:00Z", .rfc3339) }, &context));
        try t.expectInvalid(.{ .code = codes.DATETIME_MAX, .data = .{ .max = "2023-06-20T00:00:00Z" } }, context);
    }

    {
        t.reset(&context);
        const d = try typed.DateTime.parse("2023-06-20T00:00:00Z", .rfc3339);
        try t.expectEqual(typed.Value{ .datetime = d }, try validator.validateValue(.{ .datetime = d }, &context));
        try t.expectEqual(true, context.isValid());
    }

    {
        t.reset(&context);
        const d = try typed.DateTime.parse("2023-05-31T00:00:00Z", .rfc3339);
        try t.expectEqual(typed.Value{ .datetime = d }, try validator.validateValue(.{ .datetime = d }, &context));
        try t.expectEqual(true, context.isValid());
    }
}

test "datetime: parse rfc3339" {
    var context = try Context(void).init(t.allocator, .{ .max_errors = 2, .max_nesting = 1 }, {});
    defer context.deinit(t.allocator);

    const builder = try Builder(void).init(t.allocator);
    defer builder.deinit(t.allocator);

    const validator = builder.dateTime(.{ .max = try typed.DateTime.parse("2023-06-20T10:00:00Z", .rfc3339), .parse = .{ .rfc3339 = true } });

    {
        // still works fine with correct type
        try t.expectEqual(nullValue, try validator.validateValue(.{ .datetime = try typed.DateTime.parse("2023-06-21T00:00:00Z", .rfc3339) }, &context));
        try t.expectInvalid(.{ .code = codes.DATETIME_MAX, .data = .{ .max = "2023-06-20T10:00:00Z" } }, context);
    }

    {
        // parses a string and applies the validation on the parsed value
        t.reset(&context);
        try t.expectEqual(nullValue, try validator.validateValue(.{ .string = "2023-06-20T11:00:00Z" }, &context));
        try t.expectInvalid(.{ .code = codes.DATETIME_MAX, .data = .{ .max = "2023-06-20T10:00:00Z" } }, context);
    }

    {
        // parses a string and returns the typed value
        t.reset(&context);
        try t.expectEqual(try typed.DateTime.parse("2023-06-20T00:00:00Z", .rfc3339), (try validator.validateValue(.{ .string = "2023-06-20T00:00:00Z" }, &context)).datetime);
        try t.expectEqual(true, context.isValid());
    }
}

test "datetime: parse timestamp_s" {
    var context = try Context(void).init(t.allocator, .{ .max_errors = 2, .max_nesting = 1 }, {});
    defer context.deinit(t.allocator);

    const builder = try Builder(void).init(t.allocator);
    defer builder.deinit(t.allocator);

    const validator = builder.dateTime(.{ .parse = .{ .timestamp_s = true } });

    {
        // parses a string and returns the typed value
        t.reset(&context);
        try t.expectEqual(try typed.DateTime.parse("2024-03-06T08:23:50Z", .rfc3339), (try validator.validateValue(.{ .i64 = 1709713430 }, &context)).datetime);
        try t.expectEqual(true, context.isValid());
    }
}

test "datetime: parse timestamp_ms" {
    var context = try Context(void).init(t.allocator, .{ .max_errors = 2, .max_nesting = 1 }, {});
    defer context.deinit(t.allocator);

    const builder = try Builder(void).init(t.allocator);
    defer builder.deinit(t.allocator);

    const validator = builder.dateTime(.{ .parse = .{ .timestamp_ms = true } });

    {
        // parses a string and returns the typed value
        t.reset(&context);
        try t.expectEqual(try typed.DateTime.parse("2024-03-06T08:23:50.123Z", .rfc3339), (try validator.validateValue(.{ .i64 = 1709713430123 }, &context)).datetime);
        try t.expectEqual(true, context.isValid());
    }
}

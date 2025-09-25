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
    .code = codes.TYPE_STRING,
    .err = "must be a string",
};

const INVALID_BASE64 = v.Invalid{
    .code = codes.STRING_BASE64,
    .err = "must be a standard base64 encoded value",
};

const INVALID_BASE64_NO_PADDING = v.Invalid{
    .code = codes.STRING_BASE64_NO_PADDING,
    .err = "must be a standard base64 encoded value without padding",
};

const INVALID_BASE64_URL_SAFE = v.Invalid{
    .code = codes.STRING_BASE64_URL_SAFE,
    .err = "must be a url-safe base64 encoded value",
};

const INVALID_BASE64_URL_SAFE_NO_PADDING = v.Invalid{
    .code = codes.STRING_BASE64_URL_SAFE_NO_PADDING,
    .err = "must be a url-safe base64 encoded value without padding",
};

pub fn String(comptime S: type) type {
    return struct {
        required: bool,
        trim: bool,
        min: ?usize,
        max: ?usize,
        default: ?[]const u8,
        decode: ?EncodingType = null,
        choices: ?[]const []const u8 = null,
        function: ?*const fn (value: ?[]const u8, context: *Context(S)) anyerror!?[]const u8,
        invalid_min: ?v.Invalid,
        invalid_max: ?v.Invalid,
        invalid_choices: ?v.Invalid,

        const Self = @This();

        pub const EncodingType = enum {
            base64,
            base64_no_pad,
            base64_url_safe,
            base64_url_safe_no_pad,
        };

        pub const Config = struct {
            trim: bool = false,
            min: ?usize = null,
            max: ?usize = null,
            required: bool = false,
            default: ?[]const u8 = null,
            decode: ?EncodingType = null,
            choices: ?[]const []const u8 = null,
            function: ?*const fn (value: ?[]const u8, context: *Context(S)) anyerror!?[]const u8 = null,
        };

        pub fn init(allocator: Allocator, config: Config) !Self {
            var invalid_max: ?v.Invalid = null;
            var invalid_min: ?v.Invalid = null;

            const has_min = config.min != null;
            const has_max = config.max != null;

            if (has_min and has_max) {
                const min = config.min.?;
                const max = config.max.?;
                invalid_min = v.Invalid{
                    .code = codes.STRING_LEN,
                    .data = try DataBuilder.init(allocator).put("min", min).put("max", max).done(),
                    .err = try std.fmt.allocPrint(allocator, "must have {d} to {d} characters", .{ min, max }),
                };
                invalid_max = v.Invalid{
                    .code = codes.STRING_LEN,
                    .data = try DataBuilder.init(allocator).put("min", min).put("max", max).done(),
                    .err = try std.fmt.allocPrint(allocator, "must have {d} to {d} characters", .{ min, max }),
                };
            } else if (has_min) {
                const min = config.min.?;
                const plural = if (min == 1) "" else "s";
                invalid_min = v.Invalid{
                    .code = codes.STRING_LEN_MIN,
                    .data = try DataBuilder.init(allocator).put("min", min).done(),
                    .err = try std.fmt.allocPrint(allocator, "must have at least {d} character{s}", .{ min, plural }),
                };
            } else if (has_max) {
                const max = config.max.?;
                const plural = if (max == 1) "" else "s";
                invalid_max = v.Invalid{
                    .code = codes.STRING_LEN_MAX,
                    .data = try DataBuilder.init(allocator).put("max", max).done(),
                    .err = try std.fmt.allocPrint(allocator, "must have no more than {d} character{s}", .{ max, plural }),
                };
            }

            var invalid_choices: ?v.Invalid = null;
            var owned_choices: ?[][]u8 = null;
            if (config.choices) |choices| {
                var choice_data = typed.Array{};
                try choice_data.ensureTotalCapacity(allocator, choices.len);

                var owned = try allocator.alloc([]u8, choices.len);
                for (choices, 0..) |choice, i| {
                    owned[i] = try allocator.alloc(u8, choice.len);
                    @memcpy(owned[i], choice);
                    choice_data.appendAssumeCapacity(.{ .string = owned[i] });
                }
                owned_choices = owned;

                const choice_list = try std.mem.join(allocator, ", ", owned);
                invalid_choices = v.Invalid{
                    .code = codes.STRING_CHOICE,
                    .data = try DataBuilder.init(allocator).put("valid", choice_data).done(),
                    .err = try std.fmt.allocPrint(allocator, "must be one of: {s}", .{choice_list}),
                };
            }

            return .{
                .min = config.min,
                .max = config.max,
                .trim = config.trim,
                .decode = config.decode,
                .choices = owned_choices,
                .default = config.default,
                .required = config.required,
                .function = config.function,
                .invalid_min = invalid_min,
                .invalid_max = invalid_max,
                .invalid_choices = invalid_choices,
            };
        }

        pub fn validator(self: *Self) Validator(S) {
            return Validator(S).init(self);
        }

        pub fn trySetRequired(self: *Self, req: bool, builder: *Builder(S)) !*String(S) {
            var clone = try builder.allocator.create(String(S));
            clone.* = self.*;
            clone.required = req;
            return clone;
        }
        pub fn setRequired(self: *Self, req: bool, builder: *Builder(S)) *String(S) {
            return self.trySetRequired(req, builder) catch unreachable;
        }

        // part of the Validator interface, but noop for strings
        pub fn nestField(_: *Self, _: Allocator, _: *v.Field) !void {}

        pub fn validateValue(self: *const Self, input: ?typed.Value, context: *Context(S)) !typed.Value {
            var string_value: ?[]const u8 = null;
            if (input) |untyped_value| {
                string_value = switch (untyped_value) {
                    .string => |s| s,
                    else => {
                        try context.add(INVALID_TYPE);
                        return .{ .null = {} };
                    },
                };
            }

            if (try self.validate(string_value, context)) |value| {
                return .{ .string = value };
            }
            return .{ .null = {} };
        }

        // exists to be consistent with the other validators
        pub fn validateString(self: *const Self, optional_value: ?[]const u8, context: *Context(S)) !?[]const u8 {
            return self.validate(optional_value, context);
        }

        pub fn validate(self: *const Self, optional_value: ?[]const u8, context: *Context(S)) !?[]const u8 {
            var value = optional_value orelse {
                if (self.required) {
                    try context.add(v.required);
                    return null;
                }
                return self.executeFunction(null, context);
            };

            if (self.decode) |decode_type| {
                var invalid: v.Invalid = undefined;
                var decoder: std.base64.Base64Decoder = undefined;
                switch (decode_type) {
                    .base64 => {
                        invalid = INVALID_BASE64;
                        decoder = std.base64.standard.Decoder;
                    },
                    .base64_no_pad => {
                        invalid = INVALID_BASE64_NO_PADDING;
                        decoder = std.base64.standard_no_pad.Decoder;
                    },
                    .base64_url_safe => {
                        invalid = INVALID_BASE64_URL_SAFE;
                        decoder = std.base64.url_safe.Decoder;
                    },
                    .base64_url_safe_no_pad => {
                        invalid = INVALID_BASE64_URL_SAFE_NO_PADDING;
                        decoder = std.base64.url_safe_no_pad.Decoder;
                    },
                }

                const n = decoder.calcSizeForSlice(value) catch {
                    try context.add(invalid);
                    return null;
                };

                const decoded = try context.allocator.alloc(u8, n);
                decoder.decode(decoded, value) catch {
                    try context.add(invalid);
                    return null;
                };

                value = decoded;
            }

            if (self.trim) {
                value = std.mem.trim(u8, value, &std.ascii.whitespace);
                if (value.len == 0) {
                    if (self.required) {
                        try context.add(v.required);
                        return null;
                    }
                    return self.executeFunction(null, context);
                }
            }

            if (self.min) |m| {
                if (value.len < m) {
                    if (value.len == 0 and m == 1) {
                        // "Required" is a more user-friendly error message when the input
                        // is blank and min is set to 1.
                        try context.add(v.required);
                    } else {
                        try context.add(self.invalid_min.?);
                    }
                    return null;
                }
            }

            if (self.max) |m| {
                if (value.len > m) {
                    try context.add(self.invalid_max.?);
                    return null;
                }
            }

            choice_blk: {
                if (self.choices) |choices| {
                    for (choices) |choice| {
                        if (std.mem.eql(u8, choice, value)) break :choice_blk;
                    }
                    try context.add(self.invalid_choices.?);
                    return null;
                }
            }
            return self.executeFunction(value, context);
        }

        fn executeFunction(self: *const Self, value: ?[]const u8, context: *Context(S)) !?[]const u8 {
            if (self.function) |f| {
                return (try f(value, context)) orelse self.default;
            }
            return value orelse self.default;
        }
    };
}

const t = @import("t.zig");
const nullValue = typed.Value{ .null = {} };
test "string: required" {
    var context = try Context(void).init(t.allocator, .{ .max_errors = 2, .max_nesting = 1 }, {});
    defer context.deinit(t.allocator);

    var builder = try Builder(void).init(t.allocator);
    defer builder.deinit(t.allocator);

    const not_required = builder.string(.{ .required = false });
    const required = not_required.setRequired(true, &builder);
    const not_required_default = builder.string(.{ .required = false, .default = "Duncan" });

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
        try t.expectString("Duncan", (try not_required_default.validateValue(null, &context)).string);
        try t.expectEqual(true, context.isValid());
    }

    {
        // test required = false when configured directly (not via setRequired)
        t.reset(&context);
        const validator = builder.string(.{ .required = false });
        try t.expectEqual(nullValue, try validator.validateValue(null, &context));
        try t.expectEqual(true, context.isValid());
    }
}

test "string: type" {
    var context = try Context(void).init(t.allocator, .{ .max_errors = 2, .max_nesting = 1 }, {});
    defer context.deinit(t.allocator);

    var builder = try Builder(void).init(t.allocator);
    defer builder.deinit(t.allocator);

    const validator = builder.string(.{});
    try t.expectEqual(nullValue, try validator.validateValue(.{ .i64 = 33 }, &context));
    try t.expectInvalid(.{ .code = codes.TYPE_STRING }, context);
}

test "string: min length" {
    var context = try Context(void).init(t.allocator, .{ .max_errors = 2, .max_nesting = 1 }, {});
    defer context.deinit(t.allocator);

    var builder = try Builder(void).init(t.allocator);
    defer builder.deinit(t.allocator);

    const validator = builder.string(.{ .min = 4 });
    {
        try t.expectEqual(nullValue, try validator.validateValue(.{ .string = "abc" }, &context));
        try t.expectInvalid(.{ .code = codes.STRING_LEN_MIN, .data = .{ .min = 4 }, .err = "must have at least 4 characters" }, context);
    }

    {
        t.reset(&context);
        try t.expectEqual(typed.Value{ .string = "abcd" }, try validator.validateValue(.{ .string = "abcd" }, &context));
        try t.expectEqual(true, context.isValid());
    }

    {
        t.reset(&context);
        try t.expectEqual(typed.Value{ .string = "abcde" }, try validator.validateValue(.{ .string = "abcde" }, &context));
        try t.expectEqual(true, context.isValid());
    }

    const singular = builder.string(.{ .min = 1 });
    {
        try t.expectEqual(nullValue, try singular.validateValue(.{ .string = "" }, &context));
        try t.expectInvalid(.{ .code = codes.REQUIRED }, context);
    }
}

test "string: max length" {
    var context = try Context(void).init(t.allocator, .{ .max_errors = 2, .max_nesting = 1 }, {});
    defer context.deinit(t.allocator);

    var builder = try Builder(void).init(t.allocator);
    defer builder.deinit(t.allocator);

    const validator = builder.string(.{ .max = 4 });

    {
        try t.expectEqual(nullValue, try validator.validateValue(.{ .string = "abcde" }, &context));
        try t.expectInvalid(.{ .code = codes.STRING_LEN_MAX, .data = .{ .max = 4 }, .err = "must have no more than 4 characters" }, context);
    }

    {
        t.reset(&context);
        try t.expectEqual(typed.Value{ .string = "abcd" }, try validator.validateValue(.{ .string = "abcd" }, &context));
        try t.expectEqual(true, context.isValid());
    }

    {
        t.reset(&context);
        try t.expectEqual(typed.Value{ .string = "abc" }, try validator.validateValue(.{ .string = "abc" }, &context));
        try t.expectEqual(true, context.isValid());
    }

    const singular = builder.string(.{ .max = 1 });
    {
        try t.expectEqual(nullValue, try singular.validateValue(.{ .string = "123" }, &context));
        try t.expectInvalid(.{ .code = codes.STRING_LEN_MAX, .data = .{ .max = 1 }, .err = "must have no more than 1 character" }, context);
    }
}

test "string: min & max length" {
    var context = try Context(void).init(t.allocator, .{ .max_errors = 2, .max_nesting = 1 }, {});
    defer context.deinit(t.allocator);

    var builder = try Builder(void).init(t.allocator);
    defer builder.deinit(t.allocator);

    const validator = builder.string(.{ .min = 2, .max = 4 });

    {
        try t.expectEqual(nullValue, try validator.validateValue(.{ .string = "abcde" }, &context));
        try t.expectInvalid(.{ .code = codes.STRING_LEN, .data = .{ .min = 2, .max = 4 }, .err = "must have 2 to 4 characters" }, context);
    }

    {
        try t.expectEqual(nullValue, try validator.validateValue(.{ .string = "a" }, &context));
        try t.expectInvalid(.{ .code = codes.STRING_LEN, .data = .{ .min = 2, .max = 4 }, .err = "must have 2 to 4 characters" }, context);
    }

    {
        t.reset(&context);
        try t.expectEqual(typed.Value{ .string = "abcd" }, try validator.validateValue(.{ .string = "abcd" }, &context));
        try t.expectEqual(true, context.isValid());
    }

    {
        t.reset(&context);
        try t.expectEqual(typed.Value{ .string = "ab" }, try validator.validateValue(.{ .string = "ab" }, &context));
        try t.expectEqual(true, context.isValid());
    }
}

test "string: choices" {
    var context = try Context(void).init(t.allocator, .{ .max_errors = 2, .max_nesting = 1 }, {});
    defer context.deinit(t.allocator);

    var builder = try Builder(void).init(t.allocator);
    defer builder.deinit(t.allocator);

    const validator = builder.string(.{ .choices = &.{ "one", "two", "three" } });

    {
        try t.expectEqual(nullValue, try validator.validateValue(.{ .string = "nope" }, &context));
        try t.expectInvalid(.{ .code = codes.STRING_CHOICE, .data = .{ .valid = &.{ "one", "two", "three" } } }, context);

        {
            t.reset(&context);
            try t.expectString("two", (try validator.validateValue(.{ .string = "two" }, &context)).string);
            try t.expectEqual(true, context.isValid());
        }
        {
            t.reset(&context);
            try t.expectString("three", (try validator.validateValue(.{ .string = "three" }, &context)).string);
            try t.expectEqual(true, context.isValid());
        }

        {
            t.reset(&context);
            try t.expectString("one", (try validator.validateValue(.{ .string = "one" }, &context)).string);
            try t.expectEqual(true, context.isValid());
        }
    }

    var validator2: *String(void) = undefined;
    {
        const c1 = try t.allocator.dupe(u8, "hello");
        const c2 = try t.allocator.dupe(u8, "you");

        var choices2 = try t.allocator.alloc([]u8, 2);
        choices2[0] = c1;
        choices2[1] = c2;

        validator2 = builder.string(.{ .choices = choices2 });
        defer t.allocator.free(c1);
        defer t.allocator.free(c2);
        defer t.allocator.free(choices2);
    }

    {
        t.reset(&context);
        try t.expectEqual(nullValue, try validator2.validateValue(.{ .string = "nope" }, &context));
        try t.expectInvalid(.{ .code = codes.STRING_CHOICE }, context);
    }

    t.reset(&context);
    try t.expectEqual(typed.Value{ .string = "hello" }, try validator2.validateValue(.{ .string = "hello" }, &context));
    try t.expectEqual(true, context.isValid());
}

test "string: function" {
    var context = try Context(i64).init(t.allocator, .{ .max_errors = 2, .max_nesting = 1 }, 101);
    defer context.deinit(t.allocator);

    var builder = try Builder(i64).init(t.allocator);
    defer builder.deinit(t.allocator);

    const validator = builder.string(.{ .function = testStringValidator });

    {
        try t.expectEqual(nullValue, try validator.validateValue(.{ .string = "ok" }, &context));
        try t.expectEqual(true, context.isValid());
    }

    {
        try t.expectString("is-null", (try validator.validateValue(null, &context)).string);
        try t.expectEqual(true, context.isValid());
    }

    {
        t.reset(&context);
        try t.expectString("19", (try validator.validateValue(.{ .string = "change" }, &context)).string);
        try t.expectEqual(true, context.isValid());
    }

    {
        t.reset(&context);
        try t.expectEqual(nullValue, try validator.validateValue(.{ .string = "fail" }, &context));
        try t.expectInvalid(.{ .code = 999, .err = "string validation error" }, context);
    }
}

test "string: encoding" {
    var context = try Context(void).init(t.allocator, .{ .max_errors = 2, .max_nesting = 1 }, {});
    defer context.deinit(t.allocator);

    var builder = try Builder(void).init(t.allocator);
    defer builder.deinit(t.allocator);

    const validator = builder.string(.{ .max = 5, .decode = .base64 });

    {
        try t.expectEqual(nullValue, try validator.validateValue(.{ .string = "not encoded!" }, &context));
        try t.expectInvalid(.{ .code = codes.STRING_BASE64 }, context);
    }

    {
        t.reset(&context);
        try t.expectString("hello", (try validator.validateValue(.{ .string = "aGVsbG8=" }, &context)).string);
        try t.expectEqual(true, context.isValid());
    }

    {
        t.reset(&context);
        try t.expectEqual(nullValue, try validator.validateValue(.{ .string = "aGVsbG8h" }, &context));
        try t.expectInvalid(.{ .code = codes.STRING_LEN_MAX, .data = .{ .max = 5 } }, context);
    }
}

test "string: trim" {
    var context = try Context(void).init(t.allocator, .{ .max_errors = 2, .max_nesting = 1 }, {});
    defer context.deinit(t.allocator);

    var builder = try Builder(void).init(t.allocator);
    defer builder.deinit(t.allocator);

    const validator = builder.string(.{ .trim = true, .min = 2 });

    {
        try t.expectEqual(nullValue, try validator.validateValue(null, &context));
        try t.expectEqual(true, context.isValid());
    }

    {
        t.reset(&context);
        try t.expectString("abc", (try validator.validateValue(.{ .string = " \t\n abc \t\n\r  " }, &context)).string);
        try t.expectEqual(true, context.isValid());
    }

    {
        t.reset(&context);
        try t.expectEqual(nullValue, try validator.validateValue(.{ .string = " \t\n a \t\n\r  " }, &context));
        try t.expectInvalid(.{ .code = codes.STRING_LEN_MIN, .data = .{ .min = 2 } }, context);
    }
}

fn testStringValidator(value: ?[]const u8, context: *Context(i64)) !?[]const u8 {
    std.debug.assert(context.state == 101);

    const s = value orelse return "is-null";

    if (std.mem.eql(u8, s, "change")) {
        // test the arena allocator while we're here
        var alt = try context.allocator.alloc(u8, 2);
        alt[0] = '1';
        alt[1] = '9';
        return alt;
    }

    if (std.mem.eql(u8, s, "fail")) {
        try context.add(v.Invalid{
            .code = 999,
            .err = "string validation error",
        });
        return null;
    }

    return null;
}

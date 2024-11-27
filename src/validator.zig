const std = @import("std");
const localize = @import("localize");

const json = std.json;
const validate = @import("validate.zig");

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const BuiltinCode = enum(i32) {
    required = 6000,
    string_type = 6001,
    string_len = 6002,
    string_len_min = 6003,
    string_len_max = 6004,
    int_type = 6010,
    int_min = 6011,
    int_max = 6012,
    int_range = 6013,
    bool_type = 6020,
};

pub fn Validator(comptime A: type) type {
    return struct {
        // # of errors we have
        len: usize,

        locale: *const localize.Locale,

        // arena
        _allocator: Allocator,

        _errors: []Error,

        _pool: *validate.Validators(A),

        const Self = @This();
        pub const Code = ErrorCode(A);
        pub const Int = validate.Int.Validator(Self);
        pub const Bool = validate.Bool.Validator(Self);
        pub const String = validate.String.Validator(Self);
        pub const NullableString = validate.NullableString.Validator(Self);

        pub fn init(pool: *validate.Validators(A)) !Self {
            const allocator = pool._allocator;

            const arena = try allocator.create(ArenaAllocator);
            errdefer allocator.destroy(arena);

            arena.* = ArenaAllocator.init(allocator);
            errdefer arena.deinit();

            // Can't be owned by the arena. We reset the arena when reusing a validator.
            // But errors exists for the lifetime of the Validator
            const _errors = try allocator.alloc(Error, pool._max_errors);
            errdefer allocator.free(_errors);

            return .{
                .len = 0,
                ._pool = pool,
                ._errors = _errors,
                .locale = localize.EmptyLocale,
                ._allocator = arena.allocator(),
            };
        }

        pub fn deinit(self: Self) void {
            const arena: *std.heap.ArenaAllocator = @ptrCast(@alignCast(self._allocator.ptr));
            arena.deinit();

            const allocator = arena.child_allocator;
            allocator.destroy(arena);
            allocator.free(self._errors);
        }

        pub fn reset(self: *Self) void {
            self.len = 0;
            const arena: *std.heap.ArenaAllocator = @ptrCast(@alignCast(self._allocator.ptr));
            _ = arena.reset(.{.free_all = {}});
        }

        pub fn release(self: *Self) void {
            self.reset();
            self._pool.release(self);
        }

        pub fn errors(self: *const Self) []Error {
            return self._errors[0..self.len];
        }

        pub fn string(self: *Self, field_name: []const u8, value: anytype, opts: FieldOpts) ?String {
            const T = @TypeOf(value);
            switch (@typeInfo(T)) {
                .optional => {
                    if (value) |v| {
                        return self.string(field_name, v, opts);
                    }
                    self.invalidIfRequired(field_name, opts);
                    return null;
                },
                .@"union" => {
                    if (comptime T == json.Value) {
                        switch (value) {
                            .string => |str| return String.init(self, field_name, str),
                            .null => {
                                self.invalidIfRequired(field_name, opts);
                                return null;
                            },
                            else => {
                                // don't let this fallthrough, since we want to generate
                                // a more meaningful error message with the json value
                                // type
                                self.invalid(field_name, .string_type, .{.type = @tagName(value)});
                                return null;
                            }
                        }
                    }
                },
                .array => |arr| if (arr.child == u8) {
                    return String.init(self, field_name, value);
                },
                .pointer => if (comptime String.isString(T)) {
                    return String.init(self, field_name, value);
                },
                .null => {
                    self.invalidIfRequired(field_name, opts);
                    return null;
                },
                else => {},
            }

            self.invalid(field_name, .string_type, .{.type = @typeName(T)});
            return null;
        }

        pub fn nullableString(self: *Self, field_name: []const u8, value: anytype, opts: NullableFieldOpts) ?NullableString {
            const T = @TypeOf(value);
            switch (@typeInfo(T)) {
                .optional => {
                    if (value) |v| {
                        return self.nullableString(field_name, v, opts);
                    }
                    return NullableString.init(self, field_name, null);
                },
                .@"union" => {
                    if (comptime T == json.Value) {
                        switch (value) {
                            .string => |str| return NullableString.init(self, field_name, str),
                            .null => return NullableString.init(self, field_name, null),
                            else => {
                                // don't let this fallthrough, since we want to generate
                                // a more meaningful error message with the json value
                                // type
                                self.invalid(field_name, .string_type, .{.type = @tagName(value)});
                                return null;
                            }
                        }
                    }
                },
                .array => |arr| if (arr.child == u8) {
                    return NullableString.init(self, field_name, value);
                },
                .pointer => if (comptime String.isString(T)) {
                    return NullableString.init(self, field_name, value);
                },
                .null => return NullableString.init(self, field_name, null),
                else => {},
            }

            self.invalid(field_name, .string_type, .{.type = @typeName(T)});
            return null;
        }

        pub fn int(self: *Self, field_name: []const u8, value: anytype, opts: FieldOpts) ?Int {
            const T = @TypeOf(value);
            switch (@typeInfo(T)) {
                .int, .comptime_int => return Int.init(self, field_name, @intCast(value)),
                .optional => {
                    if (value) |v| {
                        return self.int(field_name, v, opts);
                    }
                    self.invalidIfRequired(field_name, opts);
                    return null;
                },
                .@"union" => {
                    if (comptime T == json.Value) {
                        switch (value) {
                            .integer => |n| return Int.init(self, field_name, n),
                            .null => {
                                self.invalidIfRequired(field_name, opts);
                                return null;
                            },
                            else => {
                                // don't let this fallthrough, since we want to generate
                                // a more meaningful error message with the json value
                                // type
                                self.invalid(field_name, .int_type, .{.type = @tagName(value)});
                                return null;
                            }
                        }
                    }
                },
                .null => {
                    self.invalidIfRequired(field_name, opts);
                    return null;
                },
                else => {},
            }

            self.invalid(field_name, .int_type, .{.type = @typeName(T)});
            return null;
        }

        pub fn boolean(self: *Self, field_name: []const u8, value: anytype, opts: FieldOpts) ?Bool {
            const T = @TypeOf(value);
            switch (@typeInfo(T)) {
                .bool => return Bool.init(self, field_name, value),
                .optional => {
                    if (value) |v| {
                        return self.boolean(field_name, v, opts);
                    }
                    self.invalidIfRequired(field_name, opts);
                    return null;
                },
                .@"union" => {
                    if (comptime T == json.Value) {
                        switch (value) {
                            .bool => |n| return Bool.init(self, field_name, n),
                            .null => {
                                self.invalidIfRequired(field_name, opts);
                                return null;
                            },
                            else => {
                                // don't let this fallthrough, since we want to generate
                                // a more meaningful error message with the json value
                                // type
                                self.invalid(field_name, .bool_type, .{.type = @tagName(value)});
                                return null;
                            }
                        }
                    }
                },
                .null => {
                    self.invalidIfRequired(field_name, opts);
                    return null;
                },
                else => {},
            }

            self.invalid(field_name, .bool_type, .{.type = @typeName(T)});
            return null;
        }

        pub fn invalid(self: *Self, field_name: []const u8, code: Code, data: anytype) void {
            const len = self.len;
            if (len == self._errors.len - 1) {
                return;
            }

            self._errors[len] = .{
                .code = @intFromEnum(code),
                .label = @tagName(code),
                .field = field_name,
                .data = localize.Data.initFromStruct(self._allocator, data) catch .{},
            };

            self.len = len + 1;
        }

        pub fn jsonStringify(self: *const Self, jws: anytype) !void {
            try jws.beginArray();
            const locale = self.locale;
            for (self._errors[0..self.len]) |e| {
                try jws.beginObject();

                try jws.objectField("code");
                try jws.write(e.code);

                try jws.objectField("field");
                try jws.write(e.field);

                try jws.objectField("data");
                try jws.write(e.data);

                try jws.objectField("message");

                const label = e.label;
                if (locale.get(label)) |msg| {
                    try msg.formatJson(jws, e.data);
                } else {
                    try jws.write(label);
                }

                try jws.endObject();
            }
            try jws.endArray();
        }

        fn invalidIfRequired(self: *Self, field_name: []const u8, opts: FieldOpts) void {
            if (opts.required) {
                self.invalid(field_name, .required, null);
            }
        }
    };
}

pub const Error = struct {
    code: i32,
    field: []const u8,
    data: localize.Data,
    label: []const u8,
};

pub const FieldOpts = struct {
    required: bool = false,
};

pub const NullableFieldOpts = struct {
};

fn ErrorCode(comptime App: type) type {
    if (App == void or @hasDecl(App, "Code") == false) {
        return BuiltinCode;
    }
    if (@typeInfo(App.Code) != .@"enum") {
        @compileError(@typeName(App.Code) ++ " must be an enum");
    }

    const lib_fields = @typeInfo(BuiltinCode).@"enum".fields;
    const app_fields = @typeInfo(App.Code).@"enum".fields;

    // Create an array that is big enough for all fields
    var fields: [lib_fields.len + app_fields.len]std.builtin.Type.EnumField = undefined;

    // Copy the library fields
    for (lib_fields, 0..) |f, i| {
        fields[i] = f;
    }

    // Copy the app fields
    // (we start our counter iterator, i, at lib_fields.len)
    for (app_fields, lib_fields.len..) |f, i| {
        fields[i] = f;
    }

    // Same as before
    return @Type(.{.@"enum" = .{
        .decls = &.{},
        .tag_type = i16,
        .fields = &fields,
        .is_exhaustive = true,
    }});
}

const t = @import("t.zig");
test "Validator: invalid" {
    defer t.reset();
    var v = t.validator();

    v.invalid("f1", .required, null);
    v.invalid("f2", .string_len, null);
    try t.assertErrors(v, &.{
        .{ .code = 6000, .data = .{}, .field = "f1", .label = "required"},
        .{ .code = 6002, .data = .{}, .field = "f2", .label = "string_len"},
    });
}

test "Validator: end-to-end" {
    defer t.reset();
    var v = t.validator();

    if (v.string("name", "Leto", .{})) |field_validator| {
        _ = field_validator.maxLength(2);
        _ = field_validator.minLength(10);
        try t.expectString("Leto", field_validator.value);
    }

    try t.assertErrors(v, &.{
        .{ .code = 6004, .data = try localize.Data.initFromStruct(t.arena(), .{.max = 2}), .field = "name", .label = "string_len_max"},
        .{ .code = 6003, .data = try localize.Data.initFromStruct(t.arena(), .{.min = 10}), .field = "name", .label = "string_len_min"},
    });


    const json_string = try std.json.stringifyAlloc(t.allocator, v, .{});
    defer t.allocator.free(json_string);

    var parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, json_string, .{});
    defer parsed.deinit();

    const values = parsed.value.array.items;
    try t.expectEqual(2, values.len);

    try t.expectEqual(6004, values[0].object.get("code").?.integer);
    try t.expectString("name", values[0].object.get("field").?.string);
    try t.expectString("must be no more than 2 characters", values[0].object.get("message").?.string);
    try t.expectEqual(2, values[0].object.get("data").?.object.get("max").?.integer);

    try t.expectEqual(6003, values[1].object.get("code").?.integer);
    try t.expectString("name", values[1].object.get("field").?.string);
    try t.expectString("must be at least 10 characters", values[1].object.get("message").?.string);
    try t.expectEqual(10, values[1].object.get("data").?.object.get("min").?.integer);
}

test "Validator: string required" {
    defer t.reset();
    var v = t.validator();

    try t.expectEqual(null, v.string("str", null, .{.required = true}));
    try t.assertErrors(v, &.{.{
        .code = @intFromEnum(BuiltinCode.required),
        .label = "required",
        .data = .{},
        .field = "str",
    }});

    v.reset();
    try t.expectEqual(null, v.string("str", json.Value{.null = {}}, .{.required = true}));
    try t.assertErrors(v, &.{.{
        .code = @intFromEnum(BuiltinCode.required),
        .label = "required",
        .data = .{},
        .field = "str",
    }});

    v.reset();
    try t.expectEqual(null, v.string("str", @as(?[]const u8, null), .{.required = true}));
    try t.assertErrors(v, &.{.{
        .code = @intFromEnum(BuiltinCode.required),
        .label = "required",
        .data = .{},
        .field = "str",
    }});

    v.reset();
    try t.expectEqual(null, v.string("str", null, .{.required = false}));

    v.reset();
    try t.expectEqual(null, v.string("str", json.Value{.null = {}}, .{.required = false}));

    v.reset();
    try t.expectEqual(null, v.string("str", @as(?[]const u8, null), .{.required = false}));
}

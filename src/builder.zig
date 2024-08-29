const std = @import("std");
const object = @import("object.zig");
const re = @cImport(@cInclude("regez.h"));
const v = @import("validate.zig");

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const Int = v.Int;
const Any = v.Any;
const Bool = v.Bool;
const Date = v.Date;
const Time = v.Time;
const UUID = v.UUID;
const Float = v.Float;
const Array = v.Array;
const String = v.String;
const Field = object.Field;
const Object = object.Object;
const DateTime = v.DateTime;
const Validator = v.Validator;
const FieldValidator = object.FieldValidator;

pub fn Builder(comptime S: type) type {
    return struct {
        arena: *ArenaAllocator,
        allocator: Allocator,

        const Self = @This();

        pub fn init(allocator: Allocator) !Self {
            var arena = try allocator.create(ArenaAllocator);
            errdefer allocator.destroy(arena);

            arena.* = ArenaAllocator.init(allocator);
            errdefer arena.deinit();

            return .{
                .arena = arena,
                .allocator = arena.allocator(),
            };
        }

        pub fn deinit(self: Self, allocator: Allocator) void {
            self.arena.deinit();
            allocator.destroy(self.arena);
        }

        pub fn tryAny(self: Self, config: Any(S).Config) !*Any(S) {
            const val = try self.allocator.create(Any(S));
            val.* = try Any(S).init(self.allocator, config);
            return val;
        }
        pub fn any(self: Self, config: Any(S).Config) *Any(S) {
            return self.tryAny(config) catch unreachable;
        }

        pub fn tryInt(self: Self, comptime T: type, config: Int(T, S).Config) !*Int(T, S) {
            const val = try self.allocator.create(Int(T, S));
            val.* = try Int(T, S).init(self.allocator, config);
            return val;
        }
        pub fn int(self: Self, comptime T: type, config: Int(T, S).Config) *Int(T, S) {
            return self.tryInt(T, config) catch unreachable;
        }

        pub fn tryBoolean(self: Self, config: Bool(S).Config) !*Bool(S) {
            const val = try self.allocator.create(Bool(S));
            val.* = try Bool(S).init(self.allocator, config);
            return val;
        }
        pub fn boolean(self: Self, config: Bool(S).Config) *Bool(S) {
            return self.tryBoolean(config) catch unreachable;
        }

        pub fn tryFloat(self: Self, comptime T: type, config: Float(T, S).Config) !*Float(T, S) {
            const val = try self.allocator.create(Float(T, S));
            val.* = try Float(T, S).init(self.allocator, config);
            return val;
        }
        pub fn float(self: Self, comptime T: type, config: Float(T, S).Config) *Float(T, S) {
            return self.tryFloat(T, config) catch unreachable;
        }

        pub fn tryString(self: *Self, config: String(S).Config) !*String(S) {
            const val = try self.allocator.create(String(S));
            val.* = try String(S).init(self.allocator, config);
            return val;
        }
        pub fn string(self: *Self, config: String(S).Config) *String(S) {
            return self.tryString(config) catch unreachable;
        }

        pub fn tryUuid(self: *Self, config: UUID(S).Config) !*UUID(S) {
            const val = try self.allocator.create(UUID(S));
            val.* = try UUID(S).init(self.allocator, config);
            return val;
        }
        pub fn uuid(self: *Self, config: UUID(S).Config) *UUID(S) {
            return self.tryUuid(config) catch unreachable;
        }

        pub fn tryDate(self: Self, config: Date(S).Config) !*Date(S) {
            const val = try self.allocator.create(Date(S));
            val.* = try Date(S).init(self.allocator, config);
            return val;
        }
        pub fn date(self: Self, config: Date(S).Config) *Date(S) {
            return self.tryDate(config) catch unreachable;
        }

        pub fn tryTime(self: Self, config: Time(S).Config) !*Time(S) {
            const val = try self.allocator.create(Time(S));
            val.* = try Time(S).init(self.allocator, config);
            return val;
        }
        pub fn time(self: Self, config: Time(S).Config) *Time(S) {
            return self.tryTime(config) catch unreachable;
        }

        pub fn tryDateTime(self: Self, config: DateTime(S).Config) !*DateTime(S) {
            const val = try self.allocator.create(DateTime(S));
            val.* = try DateTime(S).init(self.allocator, config);
            return val;
        }
        pub fn dateTime(self: Self, config: DateTime(S).Config) *DateTime(S) {
            return self.tryDateTime(config) catch unreachable;
        }

        pub fn tryArray(self: Self, validator: anytype, config: Array(S).Config) !*Array(S) {
            const val = try self.allocator.create(Array(S));
            val.* = try Array(S).init(self.allocator, validator, config);
            return val;
        }
        pub fn array(self: Self, validator: anytype, config: Array(S).Config) *Array(S) {
            return self.tryArray(validator, config) catch unreachable;
        }

        pub fn tryObject(self: Self, fields: []const FieldValidator(S), config: Object(S).Config) !*Object(S) {
            const allocator = self.allocator;
            var lookup = std.StringHashMap(FieldValidator(S)).init(allocator);
            try lookup.ensureTotalCapacity(@intCast(fields.len));

            for (fields) |fv| {
                var f = fv.field;
                try fv.validator.nestField(allocator, &f);
                lookup.putAssumeCapacity(f.name, .{
                    .field = f,
                    .validator = fv.validator,
                });
            }

            const val = try self.allocator.create(Object(S));
            val.* = try Object(S).init(self.allocator, lookup, config);

            if (config.nest) |nest| {
                var forced_parent = try self.makeField(nest);
                try val.nestField(allocator, &forced_parent);
            }

            return val;
        }
        pub fn object(self: Self, fields: []const FieldValidator(S), config: Object(S).Config) *Object(S) {
            return self.tryObject(fields, config) catch unreachable;
        }

        pub fn field(_: Self, name: []const u8, validator: anytype) FieldValidator(S) {
            const Ptr = @TypeOf(validator);
            const ptr_info = @typeInfo(Ptr);
            if (ptr_info != .pointer) @compileError("Field validator must be a pointer");

            return .{
                .field = .{
                    .name = name,
                    .path = name,
                },
                .validator = validator.validator(),
            };
        }

        pub fn makeField(_: Self, parts: []const []const u8) !Field {
            if (parts.len == 1) {
                return .{
                    .path = parts[0],
                    .name = parts[0],
                    .parts = null,
                };
            }
            return .{
                .name = "",
                .path = "",
                .parts = @constCast(parts),
            };
        }
    };
}

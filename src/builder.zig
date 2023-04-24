const std = @import("std");
const object = @import("object.zig");
const re = @cImport(@cInclude("regez.h"));

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const Int = @import("int.zig").Int;
const Any = @import("any.zig").Any;
const Bool = @import("bool.zig").Bool;
const Float = @import("float.zig").Float;
const Array = @import("array.zig").Array;
const String = @import("string.zig").String;
const Validator = @import("validator.zig").Validator;
const Field = object.Field;
const Object = object.Object;

pub fn Builder(comptime S: type) type {
	return struct {
		arena: *ArenaAllocator,
		allocator: Allocator,

		// This library heavily leans on arena allocators. Every validator is
		// created within this arena. Validators can't be individually freed
		// only freeing this arena (via builder.deinit).
		// Since we generallly expect things to be long lived, this works fine.
		// Except...our String validator uses Posix's regex.h for pattern matching
		// and this C library allocates memory directly (malloc). So when we clear
		// the arena, the memory allocated by regex.h isn't freed. The solution is
		// to keep track of every regex_t * that we create and free them.
		regexes: std.ArrayList(*re.regex_t),

		const Self = @This();

		pub fn init(allocator: Allocator) !Self {
			var arena = try allocator.create(ArenaAllocator);
			errdefer allocator.destroy(arena);

			arena.* = ArenaAllocator.init(allocator);
			errdefer arena.deinit();


			return .{
				.arena = arena,
				.allocator = arena.allocator(),
				.regexes = std.ArrayList(*re.regex_t).init(arena.allocator()),
			};
		}

		pub fn deinit(self: Self, allocator: Allocator) void {
			for (self.regexes.items) |regex| {
				re.regfree(regex);
			}

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

		pub fn tryInt(self: Self, config: Int(S).Config) !*Int(S) {
			const val = try self.allocator.create(Int(S));
			val.* = try Int(S).init(self.allocator, config);
			return val;
		}
		pub fn int(self: Self, config: Int(S).Config) *Int(S) {
			return self.tryInt(config) catch unreachable;
		}

		pub fn tryBoolean(self: Self, config: Bool(S).Config) !*Bool(S) {
			const val = try self.allocator.create(Bool(S));
			val.* = try Bool(S).init(self.allocator, config);
			return val;
		}
		pub fn boolean(self: Self, config: Bool(S).Config) *Bool(S) {
			return self.tryBoolean(config) catch unreachable;
		}

		pub fn tryFloat(self: Self, config: Float(S).Config) !*Float(S) {
			const val = try self.allocator.create(Float(S));
			val.* = try Float(S).init(self.allocator, config);
			return val;
		}
		pub fn float(self: Self, config: Float(S).Config) *Float(S) {
			return self.tryFloat(config) catch unreachable;
		}

		pub fn tryString(self: *Self, config: String(S).Config) !*String(S) {
			const val = try self.allocator.create(String(S));
			val.* = try String(S).init(self.allocator, config);

			if (val.regex) |regex| {
				try self.regexes.append(regex);
			}
			return val;
		}
		pub fn string(self: *Self, config: String(S).Config) *String(S) {
			return self.tryString(config) catch unreachable;
		}

		pub fn tryArray(self: Self, validator: anytype, config: Array(S).Config) !*Array(S) {
			const val = try self.allocator.create(Array(S));
			val.* = try Array(S).init(self.allocator, validator, config);
			return val;
		}
		pub fn array(self: Self, validator: anytype, config: Array(S).Config) *Array(S) {
			return self.tryArray(validator, config) catch unreachable;
		}

		pub fn tryObject(self: Self, fields: []const Field(S), config: Object(S).Config) !*Object(S) {
			const allocator = self.allocator;
			var owned = try allocator.alloc(Field(S), fields.len);
			for (@constCast(fields), 0..) |*f, i| {
				try f.validator.nestField(allocator, f);
				owned[i] = .{
					.name = f.name,
					.path = f.path,
					.parts = f.parts,
					.validator = f.validator,
				};
			}

			const val = try self.allocator.create(Object(S));
			val.* = try Object(S).init(self.allocator, owned, config);
			return val;
		}
		pub fn object(self: Self, fields: []const Field(S), config: Object(S).Config) *Object(S) {
			return self.tryObject(fields, config) catch unreachable;
		}

		pub fn field(_: Self, name: []const u8, validator: anytype) Field(S) {
			const Ptr = @TypeOf(validator);
			const ptr_info = @typeInfo(Ptr);
			if (ptr_info != .Pointer) @compileError("Field validator must be a pointer");

			return .{
				.name = name,
				.path = name,
				.validator = validator.validator(),
			};
		}
	};
}

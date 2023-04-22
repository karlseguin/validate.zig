const std = @import("std");
const object = @import("object.zig");

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const Int = @import("int.zig").Int;
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

		pub fn tryInt(self: Self, config: Int(S).Config) !Int(S) {
			return Int(S).init(self.allocator, config);
		}
		pub fn int(self: Self, config: Int(S).Config) Int(S) {
			return self.tryInt(config) catch unreachable;
		}

		pub fn tryBoolean(self: Self, config: Bool(S).Config) !Bool(S) {
			return Bool(S).init(self.allocator, config);
		}
		pub fn boolean(self: Self, config: Bool(S).Config) Bool(S) {
			return self.tryBoolean(config) catch unreachable;
		}

		pub fn tryFloat(self: Self, config: Float(S).Config) !Float(S) {
			return Float(S).init(self.allocator, config);
		}
		pub fn float(self: Self, config: Float(S).Config) Float(S) {
			return self.tryFloat(config) catch unreachable;
		}

		pub fn tryString(self: Self, config: String(S).Config) !String(S) {
			return String(S).init(self.allocator, config);
		}
		pub fn string(self: Self, config: String(S).Config) String(S) {
			return self.tryString(config) catch unreachable;
		}

		pub fn tryArray(self: Self, validator: anytype, config: Array(S).Config) !Array(S) {
			return Array(S).init(self.allocator, validator, config);
		}
		pub fn array(self: Self, validator: anytype, config: Array(S).Config) Array(S) {
			return self.tryArray(validator, config) catch unreachable;
		}

		pub fn tryObject(self: Self, fields: []const Field(S), config: Object(S).Config) !Object(S) {
			return Object(S).init(self.allocator, fields, config);
		}
		pub fn object(self: Self, fields: []const Field(S), config: Object(S).Config) Object(S) {
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

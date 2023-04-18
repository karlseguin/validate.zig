const std = @import("std");
const object = @import("object.zig");

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const Int = @import("int.zig").Int;
const Bool = @import("bool.zig").Bool;
const Float = @import("float.zig").Float;
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

		pub fn int(self: Self, config: Int(S).Config) !Int(S) {
			return Int(S).init(self.allocator, config);
		}

		pub fn boolean(self: Self, config: Bool(S).Config) !Bool(S) {
			return Bool(S).init(self.allocator, config);
		}

		pub fn float(self: Self, config: Float(S).Config) !Float(S) {
			return Float(S).init(self.allocator, config);
		}

		pub fn string(self: Self, config: String(S).Config) !String(S) {
			return String(S).init(self.allocator, config);
		}

		pub fn object(self: Self, fields: []const Field(S), config: Object(S).Config) !Object(S) {
			return Object(S).init(self.allocator, fields, config);
		}

		pub fn field(_: Self, name: []const u8, validator: anytype) Field(S) {
			return .{
				.name = name,
				.path = name,
				.validator = validator.validator(),
			};
		}
	};
}

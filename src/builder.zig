const std = @import("std");

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const i = @import("int.zig");
const s = @import("string.zig");
const o = @import("object.zig");
const Validator = @import("validator.zig").Validator;

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

		pub fn int(self: Self, config: i.Config(S)) !i.Int(S) {
			return i.int(S, self.allocator, config);
		}

		pub fn string(self: Self, config: s.Config(S)) !s.String(S) {
			return s.string(S, self.allocator, config);
		}

		pub fn object(self: Self, fields: []const o.Field(S), config: o.Config(S)) !o.Object(S) {
			return o.object(S, self.allocator, fields, config);
		}

		pub fn field(_: Self, name: []const u8, validator: anytype) o.Field(S) {
			return .{
				.name = name,
				.path = name,
				.validator = validator.validator(),
			};
		}
	};
}

const std = @import("std");
const v = @import("validate.zig");

const Field = @import("object.zig").Field;

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const InvalidField = struct {
	code: i64,
	field: ?[]const u8,
	err: []const u8,
	data: ?v.InvalidData,
};

pub fn Context(comptime S: type) type {
	return struct {
		_error_len: u16,
		_errors: []InvalidField,
		_arena: *ArenaAllocator,
		state: S,
		allocator: Allocator,
		field: ?Field(S),

		const Self = @This();

		pub const Config = struct {
			max_depth: u8 = 10,
			max_errors: u16 = 20,
		};

		pub fn init(allocator: Allocator, config: Config, state: S) !Self {
			var arena = try allocator.create(ArenaAllocator);
			errdefer allocator.destroy(arena);

			arena.* = ArenaAllocator.init(allocator);
			errdefer arena.deinit();

			const aa = arena.allocator();

			return .{
				._error_len = 0,
				._arena = arena,
				._errors = try aa.alloc(InvalidField, config.max_errors),
				.state = state,
				.field = null,
				.allocator = arena.allocator(),
			};
		}

		pub fn deinit(self: *Self, allocator: Allocator) void {
			self._arena.deinit();
			allocator.destroy(self._arena);
		}

		pub fn reset(self: *Self) void {
			self._error_len = 0;
			self.field = null;
		}

		pub fn isValid(self: *Self) bool {
			return self._error_len == 0;
		}

		pub fn errors(self: Self) []InvalidField {
			return self._errors[0..self._error_len];
		}

		pub fn add(self: *Self, invalid: v.Invalid) !void {
			const len = self._error_len;
			const _errors = self._errors;

			if (len == _errors.len) return;

			var field_path: ?[]const u8 = null;
			if (self.field) |f| {
				field_path = f.path;
			}

			_errors[len] = InvalidField{
				.code = invalid.code,
				.field = field_path,
				.err = invalid.err,
				.data = invalid.data,
			};
			self._error_len = len + 1;
		}
	};
}

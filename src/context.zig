const std = @import("std");
const v = @import("validate.zig");

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
		state: S,
		_error_len: u16,
		_field_len: u8,
		_errors: []InvalidField,
		_fields: [][]const u8,
		_arena: *ArenaAllocator,
		allocator: Allocator,

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
				._field_len = 0,
				._arena = arena,
				._fields = try aa.alloc([]u8, config.max_depth),
				._errors = try aa.alloc(InvalidField, config.max_errors),
				.state = state,
				.allocator = arena.allocator(),
			};
		}

		pub fn deinit(self: *Self, allocator: Allocator) void {
			self._arena.deinit();
			allocator.destroy(self._arena);

		}

		pub fn reset(self: *Self) void {
			self._error_len = 0;
			self._field_len = 0;
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

			var field: ?[]const u8 = null;
			const field_len = self._field_len;
			if (field_len == 1) {
				field = self._fields[0];
			} else {
				field = try std.mem.join(self.allocator, ".", self._fields[0..field_len]);
			}

			_errors[len] = InvalidField{
				.code = invalid.code,
				.field = field,
				.err = invalid.err,
				.data = invalid.data,
			};
			self._error_len = len + 1;
		}

		pub fn startObject(self: *Self) void {
			const field_len = self._field_len;
			const max_fields = self._fields.len;
			std.debug.assert(field_len < max_fields);

			if (field_len == max_fields) {
				return;
			}

			self._field_len = field_len + 1;
		}

		pub fn endObject(self: *Self) void {
			self._field_len -= 1;
		}

		pub fn setField(self: *Self, field: []const u8) void {
			self._fields[self._field_len - 1] = field;
		}
	};
}

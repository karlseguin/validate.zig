const std = @import("std");
const t = @import("t.zig");
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
		_nesting: []usize,
		_nesting_idx: ?u8,
		state: S,
		allocator: Allocator,
		field: ?Field(S),

		const Self = @This();

		pub const Config = struct {
			max_errors: u16 = 20,
			max_nesting: u8 = 10,
		};

		pub fn init(allocator: Allocator, config: Config, state: S) !Self {
			var arena = try allocator.create(ArenaAllocator);
			errdefer allocator.destroy(arena);

			arena.* = ArenaAllocator.init(allocator);
			errdefer arena.deinit();

			const aa = arena.allocator();

			return .{
				._arena = arena,
				._error_len = 0,
				._errors = try aa.alloc(InvalidField, config.max_errors),
				._nesting_idx = null,
				._nesting = try aa.alloc(usize, config.max_nesting),
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
			self.field = null;
			self._error_len = 0;
			self._nesting_idx = null;
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

				if (self._nesting_idx) |ni| {
					field_path = try createArrayPath(self.allocator, field_path.?, self._nesting[0..(ni+1)]);
				}
			}

			_errors[len] = InvalidField{
				.code = invalid.code,
				.field = field_path,
				.err = invalid.err,
				.data = invalid.data,
			};
			self._error_len = len + 1;
		}

		pub fn startArray(self: *Self) void {
			if (self._nesting_idx) |ni| {
				self._nesting_idx = ni + 1;
			} else {
				self._nesting_idx = 0;
			}
		}

		pub fn endArray(self: *Self) void {
			var ni = self._nesting_idx.?;
			if (ni == 0) {
				self._nesting_idx = null;
			} else {
				self._nesting_idx = ni - 1;
			}
		}

		pub fn arrayIndex(self: *Self, idx: usize) void {
			self._nesting[self._nesting_idx.?] = idx;
		}
	};
}

// TODO: improve this, a lot, this was just done quick and easy to get the functionality right
fn createArrayPath(allocator: Allocator, cfmt: []const u8, indexes: []usize) ![]const u8{
	var indexes_len: usize = 0;
	for (indexes) |idx| {
		indexes_len += intLength(idx);
	}

	var fmt = cfmt;
	var n: usize = 0;
	var buf = try allocator.alloc(u8, fmt.len + indexes_len);
	for (indexes) |idx| {
		const sep = std.mem.indexOfScalar(u8, fmt, 36) orelse unreachable;
		std.mem.copy(u8, buf[n..], fmt[0..sep]);
		n += sep;
		n += std.fmt.formatIntBuf(buf[n..], idx, 10, .lower, .{});
		fmt = fmt[(sep+1)..]; // +1 to skip the 36 field separator
	}

	return buf[0..n];
}

fn intLength(value: usize) usize {
	if (value == 0) return 1;

	var n = value;
	var digits: usize = 0;
	while (n > 0) : (n /= 10) {
		digits += 1;
	}
	return digits;
}

test "intLength" {
	try t.expectEqual(@as(usize, 1), intLength(0));
	try t.expectEqual(@as(usize, 1), intLength(1));
	try t.expectEqual(@as(usize, 1), intLength(9));
	try t.expectEqual(@as(usize, 2), intLength(10));
	try t.expectEqual(@as(usize, 2), intLength(18));
	try t.expectEqual(@as(usize, 2), intLength(99));
	try t.expectEqual(@as(usize, 3), intLength(100));
	try t.expectEqual(@as(usize, 3), intLength(999));
	try t.expectEqual(@as(usize, 4), intLength(1000));
	try t.expectEqual(@as(usize, 4), intLength(9999));
	try t.expectEqual(@as(usize, 5), intLength(10000));
	try t.expectEqual(@as(usize, 5), intLength(10002));
}

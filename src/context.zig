const std = @import("std");
const t = @import("t.zig");
const v = @import("validate.zig");

const Typed = @import("typed.zig").Typed;
const Field = @import("object.zig").Field;

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const InvalidField = struct {
	field: ?[]const u8,
	code: i64,
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
		_from_pool: bool,
		state: S,
		object: Typed,
		field: ?Field(S),
		allocator: Allocator,

		const Self = @This();

		pub const Config = struct {
			max_errors: u16 = 20,
			max_nesting: u8 = 10,
			from_pool: bool = false,
		};

		pub fn init(allocator: Allocator, config: Config, state: S) !Self {
			const from_pool = config.from_pool;

			var arena = try allocator.create(ArenaAllocator);
			errdefer allocator.destroy(arena);

			arena.* = ArenaAllocator.init(allocator);
			errdefer arena.deinit();

			const aa = arena.allocator();

			// If this context is being created for the Pool, it means we plan on
			// re-using it. In this case, the _errors and _nesting are created
			// with the parent allocator. We still created an arena allocator for
			// any allocation we need while the context is checked out.
			// If the context is not created for the Pool, we can optimize the
			// code a little and use our arena allocator for _errors and _nesting.
			const persistent_allocator = if (from_pool) allocator else aa;
			const _errors = try persistent_allocator.alloc(InvalidField, config.max_errors);
			const _nesting = try persistent_allocator.alloc(usize, config.max_nesting);

			return .{
				.state = state,
				.field = null,
				.allocator = aa,
				.object = Typed.empty,
				._arena = arena,
				._error_len = 0,
				._nesting_idx = null,
				._errors = _errors,
				._nesting = _nesting,
				._from_pool = from_pool,
			};
		}

		pub fn deinit(self: *Self, allocator: Allocator) void {
			self._arena.deinit();
			if (self._from_pool) {
				// if this context wasn't pooled, then _errors and _nesting
				// were created using the arena allocator
				allocator.free(self._errors);
				allocator.free(self._nesting);
			}
			allocator.destroy(self._arena);
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
				if (self._nesting_idx) |ni| {
					field_path = try createArrayPath(self.allocator, f.parts.?, self._nesting[0..(ni+1)]);
				} else {
					field_path = f.path;
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

fn createArrayPath(allocator: Allocator, parts: [][]const u8, indexes: []usize) ![]const u8{
	var target_len: usize = 0;
	for (indexes) |idx| {
		target_len += intLength(idx);
	}
	for (parts) |p| {
		target_len += p.len + 1;
	}

	var buf = try allocator.alloc(u8, target_len - 1);

	// what index we're at in parts
	var index: usize = 0;

	// where we are in buf
	var pos: usize = 0;

	// so we can safely prepend the .
	const first = parts[0];
	if (first.len == 0) {
			pos += std.fmt.formatIntBuf(buf, indexes[index], 10, .lower, .{});
			index += 1;
	} else {
		std.mem.copy(u8, buf, first);
		pos += first.len;
	}

	for (parts[1..]) |part| {
		if (part.len == 0) {
			if (index == indexes.len) break;
			buf[pos] = '.';
			pos += 1;
			pos += std.fmt.formatIntBuf(buf[pos..], indexes[index], 10, .lower, .{});
			index += 1;
		} else {
			buf[pos] = '.';
			pos += 1;
			std.mem.copy(u8, buf[pos..], part);
			pos += part.len;
		}
	}

	return buf[0..pos];
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

test "createArrayPath" {
	{
		var parts = [_][]const u8{"user", ""};
		var indexes = [_]usize{0};
		const actual = try createArrayPath(t.allocator, &parts, &indexes);
		defer t.allocator.free(actual);
		try t.expectString("user.0", actual);
	}

	{
		var parts = [_][]const u8{"user", "", "fav", ""};
		var indexes = [_]usize{3, 232};
		const actual = try createArrayPath(t.allocator, &parts, &indexes);
		defer t.allocator.free(actual);
		try t.expectString("user.3.fav.232", actual);
	}
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

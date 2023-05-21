const std = @import("std");
const typed = @import("typed");

const Allocator = std.mem.Allocator;

pub const DataBuilder = struct {
	inner: *Inner,

	// We do this so that we can mutate the values using a fluent interface.
	// Calling ctx.genericData returns a const (tmp values are always const in zig)
	// so we can't mutate it directly.
	const Inner = struct {
		// we defer reporting any error building our Map until done() is called
		err: ?anyerror,
		root: typed.Map,

		fn put(self: *Inner, key: []const u8, value: anytype) void {
			self.root.put(key, value) catch |err| {
				self.err = err;
			};
		}
	};

	const Self = @This();

	// we expect allocator to be an ArenaAllocator which is managed by someone else!
	pub fn init(allocator: Allocator) Self {
		const inner = allocator.create(Inner) catch unreachable;
		inner.* = Inner{
			.err = null,
			.root = typed.Map.init(allocator),
		};
		return .{.inner = inner};
	}

	pub fn put(self: Self, key: [:0]const u8, value: anytype) Self {
		self.inner.put(key, value);
		return self;
	}

	pub fn done(self: Self) !typed.Value {
		const inner = self.inner;
		if (inner.err) |err| {
			return err;
		}
		return .{.map = inner.root};
	}
};

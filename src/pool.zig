const std = @import("std");
const t = @import("t.zig");
const v = @import("validate.zig");
const Map = @import("typed").Map;

const Allocator = std.mem.Allocator;
pub const Config = struct{
	size: u16 = 50,
	max_errors: u16 = 20,
	max_nesting: u8 = 10,
};

pub fn Pool(comptime S: type) type {
	const Context = @import("context.zig").Context(S);

	return struct {
		contexts: []*Context,
		available: usize,
		allocator: Allocator,
		mutex: std.Thread.Mutex,
		config: Context.Config,

		const Self = @This();

		pub fn init(allocator: Allocator, pool_config: Config) !Self {
			const config = Context.Config{
				.from_pool = true,
				.max_errors = pool_config.max_errors,
				.max_nesting = pool_config.max_nesting,
			};

			const contexts = try allocator.alloc(*Context, pool_config.size);

			for (0..contexts.len) |i| {
				contexts[i] = try createContext(allocator, config);
			}

			return .{
				.mutex = .{},
				.config = config,
				.contexts = contexts,
				.allocator = allocator,
				.available = contexts.len,
			};
		}

		pub fn deinit(self: *Self) void {
			const allocator = self.allocator;
			for (self.contexts) |e| {
				e.deinit(allocator);
				allocator.destroy(e);
			}
			allocator.free(self.contexts);
		}

		pub fn acquire(self: *Self, state: S) !*Context {
			const contexts = self.contexts;
			self.mutex.lock();

			const available = self.available;
			if (available == 0) {
				self.mutex.unlock();
				const context = try createContext(self.allocator, self.config);
				context.state = state;
				return context;
			}
			const new_available = available - 1;
			self.available = new_available;
			const context = contexts[new_available];

			self.mutex.unlock();
			context.state = state;
			return context;
		}

		pub fn release(self: *Self, context: *Context) void {
			const contexts = self.contexts;

			self.mutex.lock();
			const available = self.available;

			if (available == contexts.len) {
				self.mutex.unlock();
				const allocator = self.allocator;
				context.deinit(allocator);
				allocator.destroy(context);
				return;
			}

			context.reset();
			defer self.mutex.unlock();
			contexts[available] = context;
			self.available = available + 1;
		}

		fn createContext(allocator: Allocator, config: Context.Config) !*Context{
			var context = try allocator.create(Context);
			context.* = try Context.init(allocator, config, undefined);
			return context;
		}
	};
}

test "pool: acquires & release" {
	var p = try Pool(void).init(t.allocator, .{.size = 2, .max_errors = 1, .max_nesting = 1});
	defer p.deinit();

	var c1a = try p.acquire({});
	var c2a = try p.acquire({});
	var c3a = try p.acquire({});

	try t.expectEqual(false, c1a == c2a);
	try t.expectEqual(false, c2a == c3a);

	p.release(c1a);

	var c1b = try p.acquire({});
	try t.expectEqual(true, c1a == c1b);

	p.release(c3a);
	p.release(c2a);
	p.release(c1b);
}

test "pool: reset" {
	var p = try Pool(void).init(t.allocator, .{.size = 2, .max_errors = 1, .max_nesting = 1});
	defer p.deinit();

	var c = try p.acquire({});
	try t.expectEqual(true, c.isValid());
	try t.expectEqual(@as(usize, 0), c.errors().len);
	try c.add(v.required);
	try t.expectEqual(false, c.isValid());
	try t.expectEqual(@as(usize, 1), c.errors().len);
	p.release(c);

	c = try p.acquire({});
	try t.expectEqual(true, c.isValid());
	try t.expectEqual(@as(usize, 0), c.errors().len);
}

test "pool: threadsafety" {
	var p = try Pool(bool).init(t.allocator, .{.size = 4});
	defer p.deinit();

	const t1 = try std.Thread.spawn(.{}, testPool, .{&p});
	const t2 = try std.Thread.spawn(.{}, testPool, .{&p});
	const t3 = try std.Thread.spawn(.{}, testPool, .{&p});
	const t4 = try std.Thread.spawn(.{}, testPool, .{&p});
	const t5 = try std.Thread.spawn(.{}, testPool, .{&p});

	t1.join(); t2.join(); t3.join(); t4.join(); t5.join();
}

fn testPool(p: *Pool(bool)) void {
	var r = std.rand.DefaultPrng.init(0);
	const random = r.random();

	for (0..5000) |_| {
		var c = p.acquire(true) catch unreachable;
		std.debug.assert(c.state == true);
		c.state = false;
		std.time.sleep(random.uintAtMost(u32, 100000));
		c.state = true;
		p.release(c);
	}
}

const std = @import("std");
const t = @import("t.zig");
const json = std.json;

const M = @This();

pub const Typed = struct {
	root: json.ObjectMap,

	pub fn wrap(root: json.ObjectMap) Typed {
		return .{.root = root};
	}

	pub const empty = Typed{.root = json.ObjectMap.init(undefined)};

	pub fn count(self: Typed) usize {
		return self.root.count();
	}

	pub fn int(self: Typed, field: []const u8) ?i64 {
		if (self.root.get(field)) |v| {
			return M.int(v);
		}
		return null;
	}

	pub fn intOr(self: Typed, field: []const u8, default: i64) i64 {
		return self.int(field) orelse default;
	}

	pub fn boolean(self: Typed, field: []const u8) ?bool {
		if (self.root.get(field)) |v| {
			return M.boolean(v);
		}
		return null;
	}

	pub fn booleanOr(self: Typed, field: []const u8, default: bool) bool {
		return self.boolean(field) orelse default;
	}

	pub fn float(self: Typed, field: []const u8) ?f64 {
		if (self.root.get(field)) |v| {
			return M.float(v);
		}
		return null;
	}

	pub fn floatOr(self: Typed, field: []const u8, default: f64) f64 {
		return self.float(field) orelse default;
	}

	pub fn string(self: Typed, field: []const u8) ?[]const u8 {
		if (self.root.get(field)) |v| {
			return M.string(v);
		}
		return null;
	}

	pub fn stringOr(self: Typed, field: []const u8, default: []const u8) []const u8 {
		return self.string(field) orelse default;
	}

	pub fn array(self: Typed, field: []const u8) ?json.Array {
		if (self.root.get(field)) |v| {
			return M.array(v);
		}
		return null;
	}

	pub fn object(self: Typed, field: []const u8) ?Typed {
		if (self.root.get(field)) |v| {
			return M.object(v);
		}
		return null;
	}
};

pub fn boolean(value: json.Value) ?bool {
	switch (value) {
		.Bool => |b| return b,
		else => return null,
	}
}

pub fn int(value: json.Value) ?i64 {
	switch (value) {
		.Integer => |n| return n,
		else => return null,
	}
}

pub fn float(value: json.Value) ?f64 {
	switch (value) {
		.Float => |f| return f,
		else => return null,
	}
}

pub fn string(value: json.Value) ?[]const u8 {
	switch (value) {
		.String => |s| return s,
		else => return null,
	}
}

pub fn array(value: json.Value) ?json.Array {
	switch (value) {
		.Array => |a| return a,
		else => return null,
	}
}

pub fn object(value: json.Value) ?Typed {
	switch (value) {
		.Object => |o| return .{.root = o},
		else => return null,
	}
}

test "typed: field access" {
	const tc = testJson(\\
	\\{
	\\ "tea": true,
	\\ "coffee": false,
	\\ "quality": 9.4,
	\\ "quantity": 88,
	\\ "type": "keemun",
	\\ "power": {"over": 9000}
	\\}
	);
	defer tc.deinit();
	const typed = tc.typed;

	try t.expectEqual(true, typed.boolean("tea").?);
	try t.expectEqual(false, typed.boolean("coffee").?);
	try t.expectEqual(@as(?bool, null), typed.boolean("nope"));
	try t.expectEqual(@as(?bool, null), typed.boolean("quality"));
	try t.expectEqual(true, typed.booleanOr("tea", false));
	try t.expectEqual(true, typed.booleanOr("nope", true));

	try t.expectEqual(@as(f64, 9.4), typed.float("quality").?);
	try t.expectEqual(@as(?f64, null), typed.float("nope"));
	try t.expectEqual(@as(?f64, null), typed.float("tea"));
	try t.expectEqual(@as(f64, 9.4), typed.floatOr("quality", 0.1));
	try t.expectEqual(@as(f64, 0.32), typed.floatOr("nope", 0.32));

	try t.expectEqual(@as(i64, 88), typed.int("quantity").?);
	try t.expectEqual(@as(?i64, null), typed.int("coffee"));
	try t.expectEqual(@as(?i64, null), typed.int("quality"));
	try t.expectEqual(@as(i64, 88), typed.intOr("quantity", -3));
	try t.expectEqual(@as(?i64, -32), typed.intOr("coffee", -32));

	try t.expectString(@as([]const u8, "keemun"), typed.string("type").?);
	try t.expectEqual(@as(?[]const u8, null), typed.string("coffee"));
	try t.expectEqual(@as(?[]const u8, null), typed.string("quality"));
	try t.expectString(@as([]const u8, "keemun"), typed.stringOr("type", "heh"));
	try t.expectString(@as([]const u8, "high"), typed.stringOr("quality", "high"));

	try t.expectEqual(@as(i64, 9000), typed.object("power").?.int("over").?);
	try t.expectEqual(@as(?Typed, null), typed.object("nope"));
	try t.expectEqual(@as(?Typed, null), typed.object("quantity"));
}

test "typed: int array" {
	const tc = testJson(\\
	\\{
	\\ "values": [1, 2, 3, true]
	\\}
	);
	defer tc.deinit();
	const typed = tc.typed;

	const values = typed.array("values").?;
	try t.expectEqual(@as(usize, 4), values.items.len);
	try t.expectEqual(@intCast(i64, 1), int(values.items[0]).?);
	try t.expectEqual(@intCast(i64, 2), int(values.items[1]).?);
	try t.expectEqual(@intCast(i64, 3), int(values.items[2]).?);
	try t.expectEqual(@as(?i64, null), int(values.items[3]));
}

test "typed: float array" {
	const tc = testJson(\\
	\\{
	\\ "values": [1.1, 2.2, 3.3, "a"]
	\\}
	);
	defer tc.deinit();
	const typed = tc.typed;

	const values = typed.array("values").?;
	try t.expectEqual(@as(usize, 4), values.items.len);
	try t.expectEqual(@as(f64, 1.1), float(values.items[0]).?);
	try t.expectEqual(@as(f64, 2.2), float(values.items[1]).?);
	try t.expectEqual(@as(f64, 3.3), float(values.items[2]).?);
	try t.expectEqual(@as(?f64, null), float(values.items[3]));
}

test "typed: bool array" {
	const tc = testJson(\\
	\\{
	\\ "values": [true, false, true, 12]
	\\}
	);
	defer tc.deinit();
	const typed = tc.typed;

	const values = typed.array("values").?;
	try t.expectEqual(@as(usize, 4), values.items.len);
	try t.expectEqual(@as(bool, true), boolean(values.items[0]).?);
	try t.expectEqual(@as(bool, false), boolean(values.items[1]).?);
	try t.expectEqual(@as(bool, true), boolean(values.items[2]).?);
	try t.expectEqual(@as(?bool, null), boolean(values.items[3]));
}

test "typed: string array" {
	const tc = testJson(\\
	\\{
	\\ "values": ["abc", "123", "tea", 1]
	\\}
	);
	defer tc.deinit();
	const typed = tc.typed;

	const values = typed.array("values").?;
	try t.expectEqual(@as(usize, 4), values.items.len);
	try t.expectString("abc", string(values.items[0]).?);
	try t.expectString("123", string(values.items[1]).?);
	try t.expectString("tea", string(values.items[2]).?);
	try t.expectEqual(@as(?[]const u8, null), string(values.items[3]));
}

test "typed: object array" {
	const tc = testJson(\\
	\\{
	\\ "values": [{"over":1}, {"over":2}, {"over":3}, 33]
	\\}
	);
	defer tc.deinit();
	const typed = tc.typed;

	const values = typed.array("values").?;
	try t.expectEqual(@as(usize, 4), values.items.len);
	try t.expectEqual(@as(i64, 1), object(values.items[0]).?.int("over").?);
	try t.expectEqual(@as(i64, 2), object(values.items[1]).?.int("over").?);
	try t.expectEqual(@as(i64, 3), object(values.items[2]).?.int("over").?);
	try t.expectEqual(@as(?Typed, null), object(values.items[3]));
}

const TestContainer = struct {
	tree: std.json.ValueTree,
	typed: Typed,

	fn deinit(self: TestContainer)  void {
		var tree = self.tree;
		tree.deinit();
	}
};

fn testJson(data: []const u8) TestContainer {
	var parser = std.json.Parser.init(t.allocator, false);
	defer parser.deinit();

	var tree = parser.parse(data) catch unreachable;
	return .{
		.tree = tree,
		.typed = .{.root = tree.root.Object},
	};
}

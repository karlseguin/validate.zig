const std = @import("std");
const Context = @import("context.zig").Context;

pub const expect = std.testing.expect;
pub const allocator = std.testing.allocator;

pub const expectEqual = std.testing.expectEqual;
pub const expectError = std.testing.expectError;
pub const expectString = std.testing.expectEqualStrings;

const InvalidExpectation = struct {
	code: ?i64 = null,
	field: ?[]const u8 = null,
	data_min: ?i64 = null,
	data_max: ?i64 = null,
};

pub fn expectInvalid(e: InvalidExpectation, context: Context(void)) !void {
	for (context.errors()) |invalid| {
		if (e.code) |expected_code| {
			if (invalid.code != expected_code) continue;
		}
		if (e.field) |expected_field| {
			if (invalid.field) |actual_field| {
				if (!std.mem.eql(u8, expected_field, actual_field)) continue;
			}
		}

		if (e.data_min) |expected_min| {
			if (invalid.data) |actual_data| {
				switch (actual_data) {
					.min => |d| if (d.min != expected_min) continue,
					else => continue,
				}
			}
		}

		if (e.data_max) |expected_max| {
			if (invalid.data) |actual_data| {
				switch (actual_data) {
					.max => |d| if (d.max != expected_max) continue,
					else => continue,
				}
			}
		}
		return;
	}
	return error.MissingExpectedInvalid;
}

pub fn validate(data: []const u8, validator: anytype, context: *Context(void)) void {
	var parser = std.json.Parser.init(allocator, false);
	defer parser.deinit();

	var tree = parser.parse(data) catch unreachable;
	defer tree.deinit();

	validator.validator().validateJson(tree.root, context) catch unreachable;
}

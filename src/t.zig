const std = @import("std");
const Context = @import("context.zig").Context;

pub const expect = std.testing.expect;
pub const allocator = std.testing.allocator;

pub const expectEqual = std.testing.expectEqual;
pub const expectError = std.testing.expectError;
pub const expectString = std.testing.expectEqualStrings;

const InvalidExpectation = struct {
	err: ?[]const u8 = null,
	code: ?i64 = null,
	field: ?[]const u8 = null,
	data_min: ?i64 = null,
	data_max: ?i64 = null,
};

pub fn expectInvalid(e: InvalidExpectation, context: anytype) !void {
	// We're going to loop through all the errors, looking for the expected one
	for (context.errors()) |invalid| {
		if (e.code) |expected_code| {
			if (invalid.code != expected_code) continue;
		}

		if (e.err) |expected_err| {
			if (!std.mem.eql(u8, expected_err, invalid.err)) continue;
		}

		if (e.field) |expected_field| {
			if (invalid.field) |actual_field| {
				if (!std.mem.eql(u8, expected_field, actual_field)) continue;
			}
		}

		if (e.data_min) |expected_min| {
			if (invalid.data) |actual_data| {
				switch (actual_data) {
					.imin => |d| if (d.min != expected_min) continue,
					else => continue,
				}
			}
		}

		if (e.data_max) |expected_max| {
			if (invalid.data) |actual_data| {
				switch (actual_data) {
					.imax => |d| if (d.max != expected_max) continue,
					else => continue,
				}
			}
		}
		return;
	}
	return error.MissingExpectedInvalid;
}

// pub fn validate(data: []const u8, validator: anytype, context: *Context(void)) ?std.json.Value {
// 	var parser = std.json.Parser.init(allocator, false);
// 	defer parser.deinit();

// 	var tree = parser.parse(data) catch unreachable;
// 	defer tree.deinit();

// 	return validator.validator().validateJson(tree.root, context) catch unreachable;
// }

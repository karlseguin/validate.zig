const std = @import("std");
const v = @import("validate.zig");

const InvalidExpectation = struct {
	err: ?[]const u8 = null,
	code: ?i64 = null,
	field: ?[]const u8 = null,
	data_min: ?i64 = null,
	data_max: ?i64 = null,
	data_fmin: ?f64 = null,
	data_fmax: ?f64 = null,
	data_pattern: ?[]const u8 = null,
	data_details: ?[]const u8 = null,
};

pub fn expectInvalid(e: InvalidExpectation, context: anytype) !void {
	return expectInvalidErrors(e, context.errors());
}

pub fn expectInvalidErrors(e: InvalidExpectation, errors: []v.InvalidField) !void {
	// We're going to loop through all the errors, looking for the expected one
	for (errors) |invalid| {
		if (e.code) |expected_code| {
			if (invalid.code != expected_code) continue;
		}

		if (e.err) |expected_err| {
			if (!std.mem.eql(u8, expected_err, invalid.err)) continue;
		}

		if (e.field) |expected_field| {
			if (invalid.field) |actual_field| {
				if (!std.mem.eql(u8, expected_field, actual_field)) continue;
			} else {
				continue;
			}
		}

		if (e.data_min) |expected_min| {
			if (invalid.data) |actual_data| {
				switch (actual_data) {
					.imin => |d| if (d.min != expected_min) continue,
					else => continue,
				}
			} else {
				continue;
			}
		}

		if (e.data_max) |expected_max| {
			if (invalid.data) |actual_data| {
				switch (actual_data) {
					.imax => |d| if (d.max != expected_max) continue,
					else => continue,
				}
			} else {
				continue;
			}
		}

		if (e.data_fmin) |expected_min| {
			if (invalid.data) |actual_data| {
				switch (actual_data) {
					.fmin => |d| if (d.min != expected_min) continue,
					else => continue,
				}
			}
		}

		if (e.data_fmax) |expected_max| {
			if (invalid.data) |actual_data| {
				switch (actual_data) {
					.fmax => |d| if (d.max != expected_max) continue,
					else => continue,
				}
			} else {
				continue;
			}
		}

		if (e.data_pattern) |expected_pattern| {
			if (invalid.data) |actual_data| {
				switch (actual_data) {
					.pattern => |p| if (!std.mem.eql(u8, p.pattern, expected_pattern)) continue,
					else => continue,
				}
			} else {
				continue;
			}
		}

		if (e.data_details) |expected_details| {
			if (invalid.data) |actual_data| {
				switch (actual_data) {
					.details => |d| if (!std.mem.eql(u8, d.details, expected_details)) continue,
					else => continue,
				}
			} else {
				continue;
			}
		}

		return;
	}
	var arr = std.ArrayList(u8).init(std.testing.allocator);
	defer arr.deinit();

	try std.json.stringify(errors, .{.whitespace = .{.indent_level = 1}}, arr.writer());
	std.debug.print("\nReceived these errors:\n {s}\n", .{arr.items});

	return error.MissingExpectedInvalid;
}

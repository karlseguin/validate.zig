const std = @import("std");
const typed = @import("typed");
const v = @import("validate.zig");

const allocator = std.testing.allocator;

pub fn expectInvalid(e: anytype, context: anytype) !void {
	const T = @TypeOf(e);
	const expected_err: ?[]const u8 = if (@hasField(T, "err")) e.err else null;
	const expected_code: ?i64 = if (@hasField(T, "code")) e.code else null;
	const expected_field: ?[]const u8 = if (@hasField(T, "field")) e.field else null;
	var expected_data: ?[]const u8 = null;
	if (@hasField(T, "data")) {
		// we go through all of this so that both actual and expected are serialized
		// as typed.Value (and thus, serialize the same, e.g. floats use the same
		// formatting options)
		var js = try std.json.stringifyAlloc(allocator, e.data, .{});
		defer allocator.free(js);

		var parser = std.json.Parser.init(allocator, .alloc_always);
		defer parser.deinit();

		var vt = try parser.parse(js);
		defer vt.deinit();

		const expected_typed = try typed.fromJson(allocator, vt.root);
		defer expected_typed.deinit();

		expected_data = try std.json.stringifyAlloc(allocator, expected_typed, .{});
	}

	defer {
		if (expected_data) |ed| allocator.free(ed);
	}

	// We're going to loop through all the errors, looking for the expected one
	const errors = context.errors();
	for (errors) |invalid| {
		if (expected_err) |er| {
			if (!std.mem.eql(u8, er, invalid.err)) continue;
		}

		if (expected_code) |ec| {
			if (invalid.code != ec) continue;
		}


		if (expected_field) |ef| {
			if (invalid.field) |actual_field| {
				if (!std.mem.eql(u8, ef, actual_field)) continue;
			} else {
				continue;
			}
		}

		if (expected_data) |ed| {
			if (invalid.data) |actual_data| {
				const actual_json = try std.json.stringifyAlloc(allocator, actual_data, .{});
				defer allocator.free(actual_json);
				if (!std.mem.eql(u8, ed, actual_json)) continue;
			} else {
				continue;
			}
		}

		return;
	}
	var arr = std.ArrayList(u8).init(allocator);
	defer arr.deinit();

	try std.json.stringify(errors, .{.whitespace = .{.indent_level = 1}}, arr.writer());
	std.debug.print("\nReceived these errors:\n {s}\n", .{arr.items});

	return error.MissingExpectedInvalid;
}

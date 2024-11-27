const std = @import("std");
const localize = @import("localize");

const t = std.testing;
const allocator = t.allocator;

pub fn expectInvalid(e: anytype, validator: anytype) !void {
    const T = @TypeOf(e);
    const expected_code: ?i64 = if (@hasField(T, "code")) e.code else null;
    const expected_field: ?[]const u8 = if (@hasField(T, "field")) e.field else null;
    const expected_message: ?[]const u8 = if (@hasField(T, "message")) e.message else null;

    // We're going to loop through all the errors, looking for the expected one
    for (validator.errors()) |err| {
        if (expected_code) |ec| {
            if (err.code != ec) continue;
        }

        if (expected_field) |ef| {
            if (!std.mem.eql(u8, ef, err.field)) continue;
        }

        if (expected_message) |em| {
            if (!std.mem.eql(u8, em, err.message)) continue;
        }

        if (@hasField(T, "data")) {
            var expected_data = try localize.Data.initFromStruct(allocator, e.data);
            defer expected_data.deinit(allocator);
            var it = expected_data._inner.iterator();
            while (it.next()) |kv| {
                const actual = err.data.get(kv.key_ptr.*) orelse return error.MissingValidationData;
                switch (kv.value_ptr.*) {
                    .null => try t.expectEqualStrings("null", @tagName(actual)),
                    .string => |ve| try t.expectEqualStrings(ve, actual.string),
                    .bool => |ve| try t.expectEqual(ve, actual.bool),
                    .i64 => |ve| {
                        switch (actual) {
                            .i64 => |va| try t.expectEqual(ve, va),
                            .u64 => |va| try t.expectEqual(ve, @as(i64, @intCast(va))),
                            else => return error.NonIntergerData,
                        }
                    },
                    .u64 => |ve| {
                        switch (actual) {
                            .u64 => |va| try t.expectEqual(ve, va),
                            .i64 => |va| try t.expectEqual(ve, @as(u64, @intCast(va))),
                            else => return error.NonIntergerData,
                        }
                    },
                    .f32 => |v| try t.expectEqual(v, actual.f32),
                    .f64 => |v| try t.expectEqual(v, actual.f64),
                }
            }
        }

        return;
    }
    var arr = std.ArrayList(u8).init(allocator);
    defer arr.deinit();

    try std.json.stringify(validator, .{ .whitespace = .indent_1 }, arr.writer());
    std.debug.print("\nReceived these errors:\n {s}\n", .{arr.items});

    return error.MissingValidation;
}

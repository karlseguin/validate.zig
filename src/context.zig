const std = @import("std");
const Map = @import("typed").Map;

const v = @import("validate.zig");
const Field = v.Field;
const DataBuilder = v.DataBuilder;

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

pub fn Context(comptime S: type) type {
    return struct {
        _error_len: u16,
        _errors: []v.InvalidField,
        _arena: *ArenaAllocator,
        _nesting: []usize,
        _nesting_idx: ?u8,
        _from_pool: bool,
        state: S,
        object: Map,
        field: ?Field,
        allocator: Allocator,
        force_prefix: ?[]const u8,

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
            const _errors = try persistent_allocator.alloc(v.InvalidField, config.max_errors);
            const _nesting = try persistent_allocator.alloc(usize, config.max_nesting);

            return .{
                .state = state,
                .field = null,
                .allocator = aa,
                .force_prefix = null,
                .object = Map.init(aa),
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

        pub fn reset(self: *Self) void {
            self.field = null;
            self._error_len = 0;
            self._nesting_idx = null;
            self.force_prefix = null;
            self.object = Map.readonlyEmpty();
            _ = self._arena.reset(.free_all);
        }

        pub fn isValid(self: *Self) bool {
            return self._error_len == 0;
        }

        pub fn errors(self: Self) []v.InvalidField {
            return self._errors[0..self._error_len];
        }

        pub fn add(self: *Self, invalid: v.Invalid) !void {
            var field_path: ?[]const u8 = null;
            if (self.field) |f| {
                if (self._nesting_idx) |ni| {
                    field_path = try createArrayPath(self.allocator, f.parts.?, self._nesting[0..(ni + 1)]);
                } else {
                    field_path = f.path;
                }
            }

            if (self.force_prefix) |prefix| {
                if (field_path) |path| {
                    var prefixed = try self.allocator.alloc(u8, prefix.len + path.len + 1);
                    @memcpy(prefixed[0..prefix.len], prefix);
                    prefixed[prefix.len] = '.';
                    @memcpy(prefixed[prefix.len + 1 ..], path);
                    field_path = prefixed;
                } else {
                    field_path = prefix;
                }
            }

            self.addInvalidField(v.InvalidField{
                .code = invalid.code,
                .field = field_path,
                .err = invalid.err,
                .data = invalid.data,
            });
        }

        pub fn addInvalidField(self: *Self, err: v.InvalidField) void {
            const len = self._error_len;
            const _errors = self._errors;
            if (len == _errors.len) return;
            _errors[len] = err;
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
            const ni = self._nesting_idx.?;
            if (ni == 0) {
                self._nesting_idx = null;
            } else {
                self._nesting_idx = ni - 1;
            }
        }

        pub fn arrayIndex(self: *Self, idx: usize) void {
            self._nesting[self._nesting_idx.?] = idx;
        }

        pub fn dataBuilder(self: Self) DataBuilder {
            return DataBuilder.init(self.allocator);
        }

        pub fn dump(self: Self) !void {
            const e = try std.json.Stringify.valueAlloc(self.allocator, self.errors(), .{});
            std.debug.print("Validation errors: \n{s}", .{e});
        }
    };
}

fn createArrayPath(allocator: Allocator, parts: [][]const u8, indexes: []usize) ![]const u8 {
    var target_len: usize = 0;
    for (indexes) |idx| {
        target_len += intLength(idx);
    }
    var index_slots: usize = 0;
    for (parts) |p| {
        if (p.len == 0) {
            index_slots += 1;
        }
        target_len += p.len + 1;
    }

    // This extra indexe stuff is only used in advanced cases where the caller
    // is manually validating nested indexes.
    const extra_indexes = if (indexes.len > index_slots) indexes[index_slots..] else &[_]usize{};
    target_len += extra_indexes.len;

    var buf = try allocator.alloc(u8, target_len - 1);

    // what index we're at in parts
    var index: usize = 0;

    // where we are in buf
    var pos: usize = 0;

    // so we can safely prepend the .
    const first = parts[0];
    if (first.len == 0) {
        var stream = std.io.fixedBufferStream(buf[pos..]);
        std.fmt.format(stream.writer(), "{d}", .{indexes[index]}) catch unreachable;
        pos += stream.getWritten().len;
        index += 1;
    } else {
        @memcpy(buf[0..first.len], first);
        pos += first.len;
    }

    for (parts[1..]) |part| {
        if (part.len == 0) {
            if (index == indexes.len) break;
            buf[pos] = '.';
            pos += 1;
            var stream = std.io.fixedBufferStream(buf[pos..]);
            std.fmt.format(stream.writer(), "{d}", .{indexes[index]}) catch unreachable;
            pos += stream.getWritten().len;
            index += 1;
        } else {
            buf[pos] = '.';
            pos += 1;
            const end = pos + part.len;
            @memcpy(buf[pos..end], part);
            pos = end;
        }
    }

    // for any extra indexes we have
    for (extra_indexes) |n| {
        buf[pos] = '.';
        pos += 1;
        var stream = std.io.fixedBufferStream(buf[pos..]);
        std.fmt.format(stream.writer(), "{d}", .{n}) catch unreachable;
        pos += stream.getWritten().len;
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

const t = @import("t.zig");
test "createArrayPath" {
    {
        var parts = [_][]const u8{ "user", "" };
        var indexes = [_]usize{0};
        const actual = try createArrayPath(t.allocator, &parts, &indexes);
        defer t.allocator.free(actual);
        try t.expectString("user.0", actual);
    }

    {
        var parts = [_][]const u8{ "user", "", "fav", "" };
        var indexes = [_]usize{ 3, 232 };
        const actual = try createArrayPath(t.allocator, &parts, &indexes);
        defer t.allocator.free(actual);
        try t.expectString("user.3.fav.232", actual);
    }

    {
        var parts = [_][]const u8{ "user", "" };
        var indexes = [_]usize{ 3, 232 };
        const actual = try createArrayPath(t.allocator, &parts, &indexes);
        defer t.allocator.free(actual);
        try t.expectString("user.3.232", actual);
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

test "context: addInvalidField with generic data" {
    var ctx = try Context(void).init(t.allocator, .{}, {});
    defer ctx.deinit(t.allocator);

    ctx.addInvalidField(v.InvalidField{
        .field = "f1",
        .code = 9101,
        .err = "nope, cannot",
        .data = try ctx.dataBuilder()
            .put("d1", null)
            .put("d2", true)
            .put("d3", @as(u8, 3))
            .put("d4", -2.3)
            .put("d5", "9000").done(),
    });

    var arr = std.array_list.Managed(u8).init(t.allocator);
    defer arr.deinit();
    const json_str = try std.json.Stringify.valueAlloc(t.allocator, ctx.errors(), .{ .emit_null_optional_fields = false });
    defer t.allocator.free(json_str);
    try arr.appendSlice(json_str);

    var parser = try std.json.parseFromSlice(std.json.Value, t.allocator, arr.items, .{});
    defer parser.deinit();

    var actual = parser.value.array.items[0].object;

    try t.expectString("f1", actual.get("field").?.string);
    try t.expectEqual(@as(i64, 9101), actual.get("code").?.integer);
    try t.expectString("nope, cannot", actual.get("err").?.string);
    const data = actual.get("data").?.object;
    try t.expectEqual({}, data.get("d1").?.null);
    try t.expectEqual(true, data.get("d2").?.bool);
    try t.expectEqual(@as(i64, 3), data.get("d3").?.integer);
    try t.expectEqual(@as(f64, -2.3), data.get("d4").?.float);
    try t.expectString("9000", data.get("d5").?.string);
}

test "context: reset" {
    var ctx = try Context(void).init(t.allocator, .{}, {});
    defer ctx.deinit(t.allocator);

    ctx.addInvalidField(v.InvalidField{
        .field = "f1",
        .code = 9101,
        .err = "nope",
        .data = null,
    });

    try t.expectEqual(false, ctx.isValid());
    try t.expectEqual(@as(usize, 1), ctx.errors().len);

    ctx.reset();

    try t.expectEqual(true, ctx.isValid());
    try t.expectEqual(@as(usize, 0), ctx.errors().len);
}

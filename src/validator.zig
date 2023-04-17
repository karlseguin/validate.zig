const std = @import("std");
const Context = @import("context.zig").Context;

pub fn Validator(comptime S: type) type {
	return struct {
		ptr: *const anyopaque,
		validateFn: *const fn(*const anyopaque, value: ?std.json.Value, context: *Context(S)) anyerror!void,

		pub fn init(ptr: anytype) Validator(S) {
			const Ptr = @TypeOf(ptr);
			const ptr_info = @typeInfo(Ptr);

			const alignment = ptr_info.Pointer.alignment;

			const gen = struct {
				pub fn validateImpl(pointer: *const anyopaque, value: ?std.json.Value, context: *Context(S)) !void {
					const self = @ptrCast(Ptr, @alignCast(alignment, pointer));
					return @call(.always_inline, ptr_info.Pointer.child.validateJson, .{self, value, context});
				}
			};

			return .{
					.ptr = ptr,
					.validateFn = gen.validateImpl,
			};
		}

		pub inline fn validateJson(self: Validator(S), value: ?std.json.Value, context: *Context(S)) !void {
			return self.validateFn(self.ptr, value, context);
		}
	};
}

const std = @import("std");
const Context = @import("context.zig").Context;

const json = std.json;

pub fn Validator(comptime S: type) type {
	return struct {
		ptr: *const anyopaque,
		validateFn: *const fn(*const anyopaque, value: ?json.Value, context: *Context(S)) anyerror!?json.Value,

		pub fn init(ptr: anytype) Validator(S) {
			const Ptr = @TypeOf(ptr);
			const ptr_info = @typeInfo(Ptr);

			const alignment = ptr_info.Pointer.alignment;

			const gen = struct {
				pub fn validateImpl(pointer: *const anyopaque, value: ?json.Value, context: *Context(S)) !?json.Value {
					const self = @ptrCast(Ptr, @alignCast(alignment, pointer));
					return @call(.always_inline, ptr_info.Pointer.child.validateJsonValue, .{self, value, context});
				}
			};

			return .{
					.ptr = ptr,
					.validateFn = gen.validateImpl,
			};
		}

		pub inline fn validateJsonValue(self: Validator(S), value: ?json.Value, context: *Context(S)) !?json.Value {
			return self.validateFn(self.ptr, value, context);
		}
	};
}

const std = @import("std");
const typed = @import("typed");
const Array = @import("array.zig").Array;
const Field = @import("validate.zig").Field;
const Context = @import("context.zig").Context;

const Allocator = std.mem.Allocator;

pub fn Validator(comptime S: type) type {
	return struct {
		ptr: *anyopaque,
		validateFn: *const fn(*anyopaque, value: ?typed.Value, context: *Context(S)) anyerror!typed.Value,
		nestFieldFn: *const fn(*anyopaque, allocator: Allocator, parent: *Field) anyerror!void,

		pub fn init(ptr: anytype) Validator(S) {
			const Ptr = @TypeOf(ptr);
			const ptr_info = @typeInfo(Ptr);

			if (ptr_info != .Pointer) @compileError("ptr must be a pointer");
			if (ptr_info.Pointer.size != .One) @compileError("ptr must be a single item pointer");

			// const alignment = ptr_info.Pointer.alignment;

			const gen = struct {
				pub fn validateImpl(pointer: *anyopaque, value: ?typed.Value, context: *Context(S)) !typed.Value {
					const self: Ptr = @ptrCast(@alignCast(pointer));
					return @call(.always_inline, ptr_info.Pointer.child.validateValue, .{self, value, context});
				}
				pub fn nestFieldImpl(pointer: *anyopaque, allocator: Allocator, parent: *Field) !void {
					const self: Ptr = @ptrCast(@alignCast(pointer));
					return @call(.always_inline, ptr_info.Pointer.child.nestField, .{self, allocator, parent});
				}
			};

			return .{
					.ptr = ptr,
					.validateFn = gen.validateImpl,
					.nestFieldFn = gen.nestFieldImpl,
			};
		}

		pub inline fn validateValue(self: Validator(S), value: ?typed.Value, context: *Context(S)) !typed.Value {
			return self.validateFn(self.ptr, value, context);
		}

		pub inline fn nestField(self: Validator(S), allocator: Allocator, parent: *Field) !void {
			return self.nestFieldFn(self.ptr, allocator, parent);
		}
	};
}

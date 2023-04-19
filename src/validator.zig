const std = @import("std");
const Array = @import("array.zig").Array;
const Field = @import("validate.zig").Field;
const Context = @import("context.zig").Context;

const json = std.json;
const Allocator = std.mem.Allocator;

pub fn Validator(comptime S: type) type {
	return struct {
		array: bool,
		ptr: *const anyopaque,
		validateFn: *const fn(*const anyopaque, value: ?json.Value, context: *Context(S)) anyerror!?json.Value,
		nestFieldFn: *const fn(*const anyopaque, allocator: Allocator, parent: *Field(S)) anyerror!void,

		pub fn init(ptr: anytype) Validator(S) {
			const Ptr = @TypeOf(ptr);
			const ptr_info = @typeInfo(Ptr);

			const alignment = ptr_info.Pointer.alignment;

			const gen = struct {
				pub fn validateImpl(pointer: *const anyopaque, value: ?json.Value, context: *Context(S)) !?json.Value {
					const self = @ptrCast(Ptr, @alignCast(alignment, pointer));
					return @call(.always_inline, ptr_info.Pointer.child.validateJsonValue, .{self, value, context});
				}
				pub fn nestFieldImpl(pointer: *const anyopaque, allocator: Allocator, parent: *Field(S)) !void {
					const self = @ptrCast(Ptr, @alignCast(alignment, pointer));
					return @call(.always_inline, ptr_info.Pointer.child.nestField, .{self, allocator, parent});
				}
			};

			return .{
					.ptr = ptr,
					.validateFn = gen.validateImpl,
					.nestFieldFn = gen.nestFieldImpl,
					.array = ptr_info.Pointer.child == Array(S),
			};
		}

		pub inline fn validateJsonValue(self: Validator(S), value: ?json.Value, context: *Context(S)) !?json.Value {
			return self.validateFn(self.ptr, value, context);
		}

		pub inline fn nestField(self: Validator(S), allocator: Allocator, parent: *Field(S)) !void {
			return self.nestFieldFn(self.ptr, allocator, parent);
		}
	};
}

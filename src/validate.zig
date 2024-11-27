const std = @import("std");
const localize = @import("localize");

const Thread = std.Thread;
const Allocator = std.mem.Allocator;

pub const Int = @import("Int.zig");
pub const Bool = @import("Bool.zig");
pub const String = @import("String.zig");
pub const NullableString = @import("NullableString.zig");

pub const Error = @import("validator.zig").Error;
pub const Validator = @import("validator.zig").Validator;

pub const testing = @import("testing.zig");

pub const Config = struct {
    count: u16 = 20,
    max_errors: u16 = 20,
};

pub fn Validators(comptime A: type) type {
    return struct {
        _max_errors: u16,
        _available: usize,
        _mutex: Thread.Mutex,
        _allocator: Allocator,
        _validators: []*Validator(A),
        _resource: localize.Resource(L),

        pub const L = Locale(A);

        const Self = @This();

        pub fn init(allocator: Allocator, config: Config) !*Self {
            var resource = try loadLocalization(A, allocator);
            errdefer resource.deinit();

            const pool = try allocator.create(Self);
            errdefer allocator.destroy(pool);

            const count = config.count;
            const validators = try allocator.alloc(*Validator(A), count);
            errdefer allocator.free(validators);

            pool.* = .{
                ._mutex = .{},
                ._available = count,
                ._resource = resource,
                ._allocator = allocator,
                ._validators = validators,
                ._max_errors = config.max_errors,
            };

            var initialized: usize = 0;
            errdefer {
                for (0..initialized) |i| {
                    validators[i].deinit();
                    allocator.destroy(validators[i]);
                }
            }

            for (0..count) |i| {
                validators[i] = try allocator.create(Validator(A));
                errdefer allocator.destroy(validators[i]);
                validators[i].* = try Validator(A).init(pool);
                initialized += 1;
            }

            return pool;
        }

        pub fn deinit(self: *Self) void {
            self._resource.deinit();

            const allocator = self._allocator;
            for (self._validators) |validator| {
                validator.deinit();
                allocator.destroy(validator);
            }
            allocator.free(self._validators);
            allocator.destroy(self);
        }

        pub fn acquire(self: *Self, locale: L) !*Validator(A) {
            const validators = self._validators;
            self._mutex.lock();
            const available = self._available;
            if (available == 0) {
                // dont hold the lock over factory
               self._mutex.unlock();

                const allocator = self._allocator;
                const validator = try allocator.create(Validator(A));
                errdefer allocator.destroy(validator);
                validator.* = try Validator(A).init(self);
                validator.locale = self._resource.getLocale(locale);
                return validator;
            }

            const index = available - 1;
            const validator = validators[index];
            self._available = index;
            self._mutex.unlock();
            validator.locale = self._resource.getLocale(locale);
            return validator;
        }

        pub fn release(self: *Self, validator: *Validator(A)) void {
            var validators = self._validators;
            self._mutex.lock();
            const available = self._available;
            if (available == validator.len) {
                self._mutex.unlock();
                validator.deinit();
                self._allocator.destroy(validator);
                return;
            }
            validators[available] = validator;
            self._available = available + 1;
            self._mutex.unlock();
        }
    };
}

fn loadLocalization(comptime A: type, allocator: Allocator) !localize.Resource(Locale(A)) {
    var resource = try localize.Resource(Locale(A)).init(allocator);
    errdefer resource.deinit();

    const data = @import("messages.zig");
    try loadLocalizationFrom(A, &resource, data);

    if (A != void and @hasDecl(A, "Messages")) {
        try loadLocalizationFrom(A, &resource, A.Messages);
    }

    return resource;
}

fn loadLocalizationFrom(comptime A: type, resource: *localize.Resource(Locale(A)), S: type) !void {
    const locale_structs = @typeInfo(S).@"struct".decls;
    inline for (locale_structs) |ls| {
        var name: [2]u8 = undefined;
        _ = std.ascii.lowerString(&name, ls.name);
        var parser = try resource.parser(std.meta.stringToEnum(Locale(A), &name).?, .{});
        defer parser.deinit();

        const messages = @field(S, ls.name);
        inline for (@typeInfo(messages).@"struct".decls) |f| {
            try parser.add(f.name, @field(messages, f.name));
        }
    }
}

const BuiltinLocale = enum(u8) {
    en = 0,
};

fn Locale(comptime App: type) type {
    if (App == void or @hasDecl(App, "Locale") == false) {
        return BuiltinLocale;
    }
    if (@typeInfo(App.Locale) != .@"enum") {
        @compileError(@typeName(App.Locale) ++ " must be an enum");
    }

    return App.Locale;
}

test {
    std.testing.refAllDecls(@This());
}

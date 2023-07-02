const toolbox = @import("toolbox.zig");
pub fn is_iterable(x: anytype) bool {
    comptime {
        const T = if (@TypeOf(x) == type) x else @TypeOf(x);
        const ti = @typeInfo(T);
        const ret = switch (ti) {
            .Pointer => |ptr_info| switch (ptr_info.size) {
                .Slice, .Many, .C => true,
                .One => !is_single_pointer(ptr_info.child) and is_iterable(ptr_info.child),
            },
            .Array => true,
            else => false,
        };
        if (@TypeOf(T) != type and ret) {
            //compile time assertion that the type is iterable
            for (x) |_| {}
        }
        return ret;
    }
}
pub fn is_single_pointer(x: anytype) bool {
    comptime {
        const T = if (@TypeOf(x) == type) x else @TypeOf(x);
        const ti = @typeInfo(T);
        switch (ti) {
            .Pointer => |ptr_info| return ptr_info.size == .One,
            else => return false,
        }
    }
}

pub fn is_string_type(comptime Type: type) bool {
    comptime {
        if (Type == toolbox.String8) {
            return true;
        }
        const ti = @typeInfo(Type);
        switch (ti) {
            .Pointer => |info| {
                return info.child == u8;
            },
            else => {
                return false;
            },
        }
    }
}

pub fn child_type(comptime Type: type) type {
    comptime {
        const ti = @typeInfo(Type);
        switch (ti) {
            .Pointer => |info| {
                return info.child;
            },
            else => {
                @compileError("Must be a pointer type!");
            },
        }
    }
}

pub fn enum_size(comptime T: type) usize {
    return comptime @typeInfo(T).Enum.fields.len;
}

pub fn ptr_cast(comptime T: type, ptr: anytype) T {
    const ti = @typeInfo(T);
    if (ti != .Pointer) {
        @compileError("T in ptr_cast must be a pointer");
    }
    return @as(T, @alignCast(ptr));
}

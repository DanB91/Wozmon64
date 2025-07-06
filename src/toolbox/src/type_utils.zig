const toolbox = @import("toolbox.zig");
pub fn is_iterable(x: anytype) bool {
    const T = if (@TypeOf(x) == type) x else @TypeOf(x);
    const ti = @typeInfo(T);
    const ret = switch (comptime ti) {
        .pointer => |ptr_info| switch (ptr_info.size) {
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
pub fn is_single_pointer(x: anytype) bool {
    const T = if (@TypeOf(x) == type) x else @TypeOf(x);
    const ti = @typeInfo(T);
    switch (comptime ti) {
        .pointer => |ptr_info| return ptr_info.size == .One,
        else => return false,
    }
}

pub fn is_string_type(comptime Type: type) bool {
    if (Type == toolbox.String8) {
        return true;
    }
    const ti = @typeInfo(Type);
    switch (comptime ti) {
        .pointer => |info| {
            return info.child == u8;
        },
        else => {
            return false;
        },
    }
}

pub fn child_type(comptime Type: type) type {
    const ti = @typeInfo(Type);
    switch (comptime ti) {
        .pointer => |info| {
            return info.child;
        },
        else => {
            @compileError("Must be a pointer type!");
        },
    }
}

pub fn enum_size(comptime T: type) usize {
    return comptime @typeInfo(T).@"enum".fields.len;
}

pub fn ptr_cast(comptime T: type, ptr: anytype) T {
    const ti = @typeInfo(T);
    if (ti != .pointer) {
        @compileError("T in ptr_cast must be a pointer");
    }
    return @as(T, @ptrCast(@alignCast(ptr)));
}

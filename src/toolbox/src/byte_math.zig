const std = @import("std");
const toolbox = @import("toolbox.zig");

pub inline fn kb(n: anytype) @TypeOf(n) {
    return n * 1024;
}

pub inline fn mb(n: anytype) @TypeOf(n) {
    return kb(n) * 1024;
}

pub inline fn gb(n: anytype) @TypeOf(n) {
    return mb(n) * 1024;
}

pub inline fn align_up(n: anytype, alignment: usize) @TypeOf(n) {
    comptime {
        switch (@typeInfo(@TypeOf(n))) {
            .Int, .ComptimeInt => {},
            else => @compileError("align_up only supports ints!"),
        }
        // if (!(alignment == 0 or (alignment & (alignment - 1)) == 0)) {
        //     @compileError("Alignment is not a power of 2!");
        // }
    }
    const unsigned_n: usize = @intCast(n);

    if (alignment == 0 or (unsigned_n % alignment) == 0) {
        return n;
    }

    return @intCast(unsigned_n + alignment - (unsigned_n % alignment));
}

pub inline fn align_down(n: anytype, alignment: usize) @TypeOf(n) {
    comptime {
        if (@typeInfo(@TypeOf(n)) != .Int) {
            @compileError("align_up only supports ints!");
        }
    }
    toolbox.assert(alignment == 0 or (alignment & (alignment - 1)) == 0, "Unexpected alignment of {}!", .{alignment});
    const unsigned_n: usize = @intCast(n);

    return @intCast(unsigned_n & ~(alignment - 1));
}
pub inline fn is_aligned_to(n: anytype, comptime alignment: usize) bool {
    comptime {
        if (@typeInfo(@TypeOf(n)) != .Int) {
            @compileError("align_up only supports ints!");
        }
        if (!(alignment == 0 or (alignment & (alignment - 1)) == 0)) {
            @compileError("Alignment is not a power of 2!");
        }
    }
    const unsigned_n: usize = @intCast(n);
    return (unsigned_n % alignment) == 0;
}

pub inline fn zig_compatible_align_up(n: anytype, alignment: u29) @TypeOf(n) {
    comptime {
        if (@typeInfo(@TypeOf(n)) != .Int) {
            @compileError("zig_compatible_align_up only supports ints!");
        }
    }
    toolbox.assert(alignment == 0 or (alignment & (alignment - 1)) == 0, "Unexpected alignment of {}!", .{alignment});

    if (alignment == 0 or (n & (alignment - 1)) == 0) {
        return n;
    }

    return n + alignment - (n & (alignment - 1));
}

pub inline fn is_power_of_2(n: anytype) bool {
    return (n & (n -% 1)) == 0;
}

pub inline fn next_power_of_2(n: anytype) @TypeOf(n) {
    if (is_power_of_2(n)) {
        return n;
    }
    var count: std.math.Log2Int(@TypeOf(n)) = 0;
    var val = n;
    while (val > 0) {
        val >>= 1;
        count += 1;
    }
    return @as(@TypeOf(n), 1) << count;
}

pub inline fn clamp(v: anytype, low: @TypeOf(v), high: @TypeOf(v)) @TypeOf(v) {
    return @max(low, @min(high, v));
}

pub inline fn mask_for_bit_range(comptime from: usize, comptime to: usize, comptime T: type) T {
    var ret: T = 0;
    inline for (from..to) |i| {
        ret |= 1 << i;
    }
    return ret;
}

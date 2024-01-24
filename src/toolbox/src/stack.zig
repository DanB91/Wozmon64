const toolbox = @import("toolbox.zig");
pub fn Stack(comptime T: type) type {
    return struct {
        data: []T = @as([*]T, undefined)[0..0],
        back: usize = 0,

        const Self = @This();

        pub fn init(arena: *toolbox.Arena, max_items: usize) Self {
            return .{
                .data = arena.push_slice(T, max_items),
                .back = 0,
            };
        }
        pub inline fn push(self: *Self, value: T) *T {
            self.data[self.back] = value;
            self.back += 1;
            return &self.data[self.back - 1];
        }
        pub inline fn pop(self: *Self) T {
            self.back -= 1;
            return self.data[self.back];
        }
        pub inline fn peek(self: *const Self) ?T {
            if (self.back >= 1) {
                return self.data[self.back - 1];
            }
            return null;
        }
        pub inline fn empty(self: *Self) bool {
            return self.back == 0;
        }
        pub inline fn clear(self: *Self) void {
            self.back = 0;
        }

        pub fn clone(self: *Self, arena: *toolbox.Arena) Self {
            const ret = init(arena, self.data.len);
            @memcpy(ret.data, self.data);
            ret.back = self.back;
            return ret;
        }
    };
}

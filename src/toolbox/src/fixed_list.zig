const toolbox = @import("toolbox.zig");
pub fn FixedList(comptime T: type, comptime max_len: usize) type {
    return struct {
        store: [max_len]T = undefined,
        len: usize = 0,

        const Self = @This();

        pub fn init_with_items(comptime values: anytype) Self {
            var ret = Self{
                .store = undefined,
                .len = values.len,
            };
            inline for (values, 0..) |v, i| {
                ret.store[i] = v;
            }
            return ret;
        }

        pub inline fn items(self: *Self) []T {
            return self.store[0..self.len];
        }
    };
}

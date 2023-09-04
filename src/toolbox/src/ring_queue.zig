const toolbox = @import("toolbox.zig");

//
//[] rcursor = 0, wcursor = 0, len = 0, max = 3
//[1] rcursor = 0, wcursor = 1, len = 1, max =3
//[1, 2] rcursor = 0, wcursor = 2, len = 2, max =3
//[1, 2, 3] rcursor = 0, wcursor = 0, len = 3, max =3
//
//
pub fn RingQueue(comptime T: type) type {
    return struct {
        data: []T,
        rcursor: usize,
        wcursor: usize,

        pub const Iterator = struct {
            cursor: usize,
            queue: *const Self,

            pub fn next(self: *@This()) ?T {
                if (self.cursor == self.queue.wcursor) {
                    return null;
                }
                const ret = self.queue.data[self.cursor];
                next_ring_index(&self.cursor, self.queue.data.len);
                return ret;
            }
        };

        const Self = @This();

        pub fn init(ring_len: usize, arena: *toolbox.Arena) Self {
            if (!toolbox.is_power_of_2(ring_len) or ring_len == 0) {
                toolbox.panic("RingQueue len must be a power of 2 that is > 0! Was: {}", .{ring_len});
            }
            return .{
                .data = arena.push_slice(T, ring_len),
                .rcursor = 0,
                .wcursor = 0,
            };
        }

        pub fn iterator(self: *const Self) Iterator {
            return .{
                .cursor = self.rcursor,
                .queue = self,
            };
        }

        pub fn clone(self: *const Self, arena: *toolbox.Arena) Self {
            var data_copy = arena.push_slice(T, self.data.len);
            for (data_copy, self.data) |*d, s| d.* = s;
            return .{
                .data = data_copy,
                .rcursor = self.rcursor,
                .wcursor = self.wcursor,
            };
        }

        pub fn clear(self: *Self) void {
            self.rcursor = 0;
            self.wcursor = 0;
        }

        pub inline fn enqueue(self: *Self, value: T) void {
            // if (self.is_full()) {
            //     toolbox.panic("Trying to enqueue full queue!", .{});
            // }
            self.data[self.wcursor] = value;
            next_ring_index(&self.wcursor, self.data.len);
            if (self.wcursor == self.rcursor) {
                next_ring_index(&self.rcursor, self.data.len);
            }
        }
        pub inline fn dequeue(self: *Self) ?T {
            if (self.is_empty()) {
                return null;
            }
            const ret = self.data[self.rcursor];
            next_ring_index(&self.rcursor, self.data.len);
            return ret;
        }
        pub inline fn is_empty(self: Self) bool {
            return self.rcursor == self.wcursor;
        }
        pub inline fn is_full(self: Self) bool {
            var tmp_cursor = self.wcursor;
            next_ring_index(&tmp_cursor, self.data.len);
            return tmp_cursor == self.rcursor;
        }
    };
}

inline fn next_ring_index(i: *usize, len: usize) void {
    i.* = (i.* + 1) & (len - 1);
}

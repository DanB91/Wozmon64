const toolbox = @import("toolbox.zig");
pub fn DynamicArray(T: type) type {
    return struct {
        store: []T,
        _len: usize = 0,

        arena: *toolbox.Arena,

        const Self = @This();

        pub fn init(arena: *toolbox.Arena, capacity: usize) Self {
            return Self{
                .arena = arena,
                .store = arena.push_slice([]T, capacity),
            };
        }

        pub fn append(self: *Self, value: T) void {
            if (self._len >= self.store.len) {
                self.ensure_capacity(@max(16, self.store.len * 2));
            }
            self.store[self._len] = value;
            self._len += 1;
        }

        pub fn len(self: *const Self) usize {
            return self._len;
        }

        pub fn clear(self: *Self) void {
            self.* = .{ .arena = self.arena };
        }

        fn ensure_capacity(self: *Self, capacity: usize) void {
            if (capacity <= self.store.len) {
                return;
            }
            const src = self.store;
            const dest = self.arena.push_slice([]T, capacity);
            for (src, 0..) |s, i| dest[i] = s;
            self.store = dest;
        }
    };
}

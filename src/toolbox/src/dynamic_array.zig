const std = @import("std");
const toolbox = @import("toolbox.zig");
pub fn DynamicArray(comptime T: type) type {
    return struct {
        store: []T,
        _len: usize = 0,

        arena: *toolbox.Arena,

        pub const Child = T;

        const Self = @This();

        pub fn init(arena: *toolbox.Arena, capacity: usize) Self {
            return Self{
                .arena = arena,
                .store = arena.push_slice(T, capacity),
            };
        }

        pub fn items(self: *Self) []T {
            return self.store[0..self._len];
        }

        pub fn append(self: *Self, value: T) void {
            if (self._len >= self.store.len) {
                self.ensure_capacity(@max(16, self.store.len * 2));
            }
            self.store[self._len] = value;
            self._len += 1;
        }

        pub inline fn len(self: *const Self) usize {
            return self._len;
        }

        pub fn clear(self: *Self) void {
            self.* = .{ .arena = self.arena };
        }

        pub const sort = switch (@typeInfo(T)) {
            .Int, .Float => sort_number,
            .Struct => sort_struct,
            else => @compileError("Unsupported type " ++ @typeName(T) ++ " for DynamicArray"),
        };

        fn sort_number(self: *Self) void {
            std.sort.block(T, self.store[0..self.len()], self, struct {
                fn less_than(context: *Self, a: T, b: T) bool {
                    _ = context;
                    return a < b;
                }
            }.less_than);
        }

        fn sort_struct(self: *Self, comptime field_name: []const u8) void {
            std.sort.block(T, self.store[0..self.len()], self, struct {
                fn less_than(context: *Self, a: T, b: T) bool {
                    _ = context;
                    return @field(a, field_name) < @field(b, field_name);
                }
            }.less_than);
        }

        pub fn clone(self: *Self, clone_arena: *toolbox.Arena) Self {
            var ret = Self.init(clone_arena, self.store.len);
            @memcpy(ret.store, self.store);
            ret._len = self._len;
            return ret;
        }

        fn ensure_capacity(self: *Self, capacity: usize) void {
            if (capacity <= self.store.len) {
                return;
            }
            const src = self.store;
            const dest = self.arena.push_slice(T, capacity);
            for (src, 0..) |s, i| dest[i] = s;
            self.store = dest;
        }
    };
}

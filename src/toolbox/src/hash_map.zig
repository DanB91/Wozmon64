const toolbox = @import("toolbox.zig");
const std = @import("std");
pub fn HashMap(comptime Key: type, comptime Value: type) type {
    return BaseHashMap(Key, Value, false);
}
pub fn PointerStableHashMap(comptime Key: type, comptime Value: type) type {
    return BaseHashMap(Key, Value, true);
}
fn BaseHashMap(comptime Key: type, comptime Value: type, comptime is_pointer_stable: bool) type {
    return struct {
        indices: toolbox.RandomRemovalLinkedList(usize) = .{},
        buckets: []?KeyValue = @as([*]?KeyValue, undefined)[0..0],

        //to keep things consistent with len(), cap() will also be a function
        _cap: usize = 0,

        //debugging fields
        hash_collisions: usize = 0,
        index_collisions: usize = 0,
        reprobe_collisions: usize = 0,
        bad_reprobe_collisions: usize = 0,

        arena: ?*toolbox.Arena = null,

        const KeyValue = struct {
            k: Key,
            v: Value,
            index_node: *usize,
        };
        const Self = @This();
        pub const Iterator = struct {
            it: toolbox.RandomRemovalLinkedList(usize).Iterator = .{},
            hash_map: ?*const Self = null,

            pub fn next(self: *Iterator) ?*KeyValue {
                if (self.it.next()) |index| {
                    return &self.hash_map.?.buckets[index.*].?;
                }
                return null;
            }
        };

        pub fn init(initial_capacity: usize, arena: *toolbox.Arena) Self {
            const num_buckets = toolbox.next_power_of_2(@as(usize, @intFromFloat(@as(f64, @floatFromInt(initial_capacity)) * 1.5)));
            const buckets = arena.push_slice_clear(?KeyValue, num_buckets);
            return Self{
                .indices = toolbox.RandomRemovalLinkedList(usize).init(arena),
                .buckets = buckets,
                ._cap = initial_capacity,

                .arena = arena,
            };
        }
        pub inline fn clear(self: *Self) void {
            self.indices.clear_and_free();
            for (self.buckets) |*bucket| bucket.* = null;
        }
        pub inline fn len(self: *const Self) usize {
            return self.indices.len;
        }
        pub inline fn cap(self: *const Self) usize {
            return self._cap;
        }

        pub fn clone(self: *const Self, clone_arena: *toolbox.Arena) Self {
            var ret = init(self.cap(), clone_arena);
            for (self.buckets, 0..) |bucket_opt, i| {
                if (bucket_opt) |bucket| {
                    const index_node = ret.indices.append(i);
                    ret.buckets[i] = .{
                        .k = bucket.k,
                        .v = bucket.v,
                        .index_node = index_node,
                    };
                }
            }
            return ret;
        }
        pub fn expand(self: *Self) Self {
            if (comptime is_pointer_stable) {
                @panic("Cannot expand a pointer stable hashmap");
            }
            if (self.arena) |arena| {
                var ret = init(self.cap() * 2, arena);
                for (self.buckets) |bucket_opt| {
                    if (bucket_opt) |bucket| {
                        ret.put(bucket.k, bucket.v);
                    }
                }
                return ret;
            } else {
                toolbox.panic("Cannot expand hash map with arena!", .{});
            }
        }

        pub fn put(self: *Self, key: Key, value: Value) void {
            var index = self.index_for_key(key);
            const kvptr = &self.buckets[index];
            if (kvptr.*) |*kv| {
                kv.v = value;
            } else if (self.len() == self.cap()) {
                self.* = self.expand();
                self.put(key, value);
            } else {
                index = self.index_for_key(key);
                const index_node = self.indices.append(index);
                kvptr.* = .{
                    .k = key,
                    .v = value,
                    .index_node = index_node,
                };
            }
        }

        pub fn get(self: *Self, key: Key) ?Value {
            toolbox.profiler.begin("Hash Map get");
            defer toolbox.profiler.end();
            if (self.len() == 0) {
                return null;
            }

            const index = self.index_for_key(key);
            if (self.buckets[index]) |kv| {
                return kv.v;
            }
            return null;
        }

        pub fn get_or_put(self: *Self, key: Key, initial_value: Value) Value {
            const index = self.index_for_key(key);
            const kvptr = &self.buckets[index];
            if (kvptr) |kv| {
                return kv.v;
            } else if (self.len() == self.cap()) {
                self.* = self.expand();
                return self.get_or_put(key, initial_value, self.arena);
            } else {
                const index_node = self.indices.append(index, self.arena);
                kvptr.* = .{
                    .k = key,
                    .v = initial_value,
                    .index_node = index_node,
                };
                return initial_value;
            }
        }

        pub fn get_ptr(self: *Self, key: Key) ?*Value {
            if (self.len() == 0) {
                return null;
            }

            const kvptr = &self.buckets[self.index_for_key(key)];
            if (kvptr.*) |*kv| {
                return &kv.v;
            }
            return null;
        }

        pub fn get_or_put_ptr(self: *Self, key: Key, initial_value: Value) *Value {
            const index = self.index_for_key(key);
            const kvptr = &self.buckets[index];
            if (kvptr.*) |*kv| {
                return &kv.v;
            } else if (self.len() == self.cap()) {
                self.* = self.expand();
                return self.get_or_put_ptr(key, initial_value);
            } else {
                const index_node = self.indices.append(index);
                kvptr.* = .{
                    .k = key,
                    .v = initial_value,
                    .index_node = index_node,
                };
                return &kvptr.*.?.v;
            }
        }

        pub fn remove(self: *Self, key: Key) void {
            const key_bytes = if (comptime toolbox.is_string_type(Key))
                to_bytes(key)
            else
                to_bytes(&key);
            const h = hash_fnv1a64(key_bytes);

            var index: usize = @intCast(h & (self.buckets.len - 1));
            var kvptr = &self.buckets[index];
            var did_delete = false;
            if (kvptr.*) |kv| {
                if (eql(kv.k, key)) {
                    self.indices.remove(kv.index_node);
                    kvptr.* = null;
                    did_delete = true;
                }
            } else {
                return;
            }

            const dest = kvptr;
            //re-probe
            {
                const index_bit_size: u6 = @intCast(@ctz(self.buckets.len));
                var i = index_bit_size;
                while (i < @bitSizeOf(usize)) : (i += index_bit_size) {
                    index = @intCast((h >> i) & (self.buckets.len - 1));
                    kvptr = &self.buckets[index];
                    if (kvptr.*) |kv| {
                        if (did_delete) {
                            dest.* = kv;
                            kvptr.* = null;
                        } else if (eql(kv.k, key)) {
                            self.indices.remove(kv.index_node);
                            kvptr.* = null;
                            did_delete = true;
                        }
                    } else {
                        return;
                    }
                }
            }

            //last ditch effort
            {
                const end = index;
                index += 1;
                while (index != end) : (index = (index + 1) & (self.buckets.len - 1)) {
                    kvptr = &self.buckets[index];
                    if (kvptr.*) |kv| {
                        if (did_delete) {
                            dest.* = kv;
                            kvptr.* = null;
                        } else if (eql(kv.k, key)) {
                            self.indices.remove(kv.index_node);
                            kvptr.* = null;
                            did_delete = true;
                        }
                    } else {
                        return;
                    }
                }
            }
            toolbox.panic("Should not get here!", .{});
        }

        pub fn iterator(self: *const Self) Iterator {
            return .{
                .it = self.indices.iterator(),
                .hash_map = self,
            };
        }

        fn index_for_key(self: *Self, key: Key) usize {
            const key_bytes = if (comptime toolbox.is_string_type(Key))
                to_bytes(key)
            else
                to_bytes(&key);
            const h = hash_fnv1a64(key_bytes);

            var index: usize = @intCast(h & (self.buckets.len - 1));
            var kvptr = &self.buckets[index];
            if (kvptr.*) |kv| {
                if (eql(kv.k, key)) {
                    return index;
                }
            } else {
                return index;
            }

            self.index_collisions += 1;
            //re-probe
            {
                const index_bit_size = @ctz(self.buckets.len);
                var i: usize = index_bit_size;
                while (i < @bitSizeOf(usize)) : (i += index_bit_size) {
                    self.reprobe_collisions += 1;
                    index = @intCast((h >> @intCast(i)) & (self.buckets.len - 1));
                    kvptr = &self.buckets[index];
                    if (kvptr.*) |kv| {
                        if (eql(kv.k, key)) {
                            return index;
                        }
                    } else {
                        return index;
                    }
                }
            }

            //last ditch effort
            {
                const end = index;
                index += 1;
                while (index != end) : (index = (index + 1) & (self.buckets.len - 1)) {
                    self.bad_reprobe_collisions += 1;
                    kvptr = &self.buckets[index];
                    if (kvptr.*) |kv| {
                        if (eql(kv.k, key)) {
                            return index;
                        }
                    } else {
                        return index;
                    }
                }
            }
            toolbox.panic("Should not get here!", .{});
        }
    };
}
pub fn hash_fnv1a64(data: []const u8) u64 {
    const seed = 0xcbf29ce484222325;
    var h: u64 = seed;
    for (data) |b| {
        h = (h ^ @as(u64, b)) *% 0x100000001b3;
    }
    return h;
}

fn to_bytes(v: anytype) []const u8 {
    const T = @TypeOf(v);
    if (comptime T == []const u8) {
        return v;
    }
    if (comptime T == toolbox.String8) {
        return v.bytes;
    }
    const ti = @typeInfo(T);
    switch (comptime ti) {
        .Pointer => |info| {
            const Child = info.child;
            switch (comptime info.size) {
                .Slice => {
                    return @as([*]const u8, @ptrCast(v.ptr))[0..@sizeOf(Child)];
                },
                else => {
                    return @as([*]const u8, @ptrCast(v))[0..@sizeOf(Child)];
                },
            }
        },
        else => {
            @compileError("Parameter must be a pointer!");
        },
    }
}

fn eql(a: anytype, b: @TypeOf(a)) bool {
    const T = @TypeOf(a);
    if (comptime T == toolbox.String8) {
        return toolbox.string_equals(a, b);
    }

    switch (comptime @typeInfo(T)) {
        .Struct => |info| {
            inline for (info.fields) |field_info| {
                if (!eql(@field(a, field_info.name), @field(b, field_info.name))) return false;
            }
            return true;
        },
        .ErrorUnion => {
            if (a) |a_p| {
                if (b) |b_p| return eql(a_p, b_p) else |_| return false;
            } else |a_e| {
                if (b) |_| return false else |b_e| return a_e == b_e;
            }
        },
        //.Union => |info| {
        //if (info.tag_type) |UnionTag| {
        //const tag_a = activeTag(a);
        //const tag_b = activeTag(b);
        //if (tag_a != tag_b) return false;

        //inline for (info.fields) |field_info| {
        //if (@field(UnionTag, field_info.name) == tag_a) {
        //return eql(@field(a, field_info.name), @field(b, field_info.name));
        //}
        //}
        //return false;
        //}

        //@compileError("cannot compare untagged union type " ++ @typeName(T));
        //},
        .Array => {
            if (a.len != b.len) return false;
            for (a, 0..) |e, i|
                if (!eql(e, b[i])) return false;
            return true;
        },
        .Vector => |info| {
            var i: usize = 0;
            while (i < info.len) : (i += 1) {
                if (!eql(a[i], b[i])) return false;
            }
            return true;
        },
        .Pointer => |info| {
            return switch (info.size) {
                .One, .Many, .C => a == b,
                //changed from std.meta.eql
                .Slice => std.mem.eql(info.child, a, b),
            };
        },
        .Optional => {
            if (a == null and b == null) return true;
            if (a == null or b == null) return false;
            return eql(a.?, b.?);
        },
        else => return a == b,
    }
}

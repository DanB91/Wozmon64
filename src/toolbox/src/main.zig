const std = @import("std");
const toolbox = @import("toolbox.zig");
const profiler = toolbox.profiler;

pub const THIS_PLATFORM = toolbox.Platform.MacOS;
pub const ENABLE_PROFILER = true; // !toolbox.IS_DEBUG;
pub const panic = toolbox.panic_handler;

pub fn main() anyerror!void {
    if (toolbox.IS_DEBUG) {
        try run_tests();
        run_benchmarks();
    } else {
        run_benchmarks();
    }
}

//TODO
//enum {
//Print,
//TypeUtils,
//Memory,
//LinkedList,
//All,
//};

fn run_tests() !void {

    //print tests
    {
        toolbox.println("Hello world!", .{});
        toolbox.println("Hello number: {}!", .{1.0234});
        toolbox.printerr("Hello error!", .{});
        //toolbox.panic("Hello panic!", .{});
    }

    //type utils tests
    {
        const i: i32 = 5;
        const string_slice: []const u8 = "Hello!";

        //iterable tests
        toolbox.assert(toolbox.is_iterable([]u8), "Byte slice should be iterable!", .{});
        toolbox.assert(!toolbox.is_iterable(i), "Number should not be iterable!", .{});
        toolbox.assert(!toolbox.is_iterable(&i), "Address-of number should not be iterable!", .{});
        toolbox.assert(toolbox.is_iterable("This is iterable"), "String should be iterable!", .{});
        toolbox.assert(toolbox.is_iterable(string_slice), "String should be iterable!", .{});

        //single pointer tests
        toolbox.assert(!toolbox.is_single_pointer(i), "Number should not be a single pointer!", .{});
        toolbox.assert(toolbox.is_single_pointer(&i), "Address-of should be a single pointer!", .{});
        toolbox.assert(toolbox.is_single_pointer("Strings are single pointers to arrays"), "Strings should be a single pointer to arrays", .{});
        toolbox.assert(!toolbox.is_single_pointer(string_slice), "Slices should not be a single pointer", .{});
    }

    //memory tests
    {
        //test system allocator
        {
            const num_bytes = toolbox.mb(1);
            const data = toolbox.os_allocate_memory(num_bytes);
            toolbox.asserteq(num_bytes, data.len, "Wrong number of bytes allocated");
            toolbox.assert(toolbox.is_aligned_to(@intFromPtr(data.ptr), toolbox.PAGE_SIZE), "System allocated memory should be page aligned", .{});
            //os allocator should returned zero'ed memory
            for (data) |b| toolbox.asserteq(b, 0, "Memory should be zeroed from system allocator");

            for (data) |*b| b.* = 0xFF;
            toolbox.os_free_memory(data);
        }

        const arena_size = toolbox.mb(1);
        var arena = toolbox.Arena.init(arena_size);
        //test init arena
        {
            toolbox.asserteq(0, arena.pos, "Arena should have initial postion of 0");
            toolbox.asserteq(arena_size - @sizeOf(toolbox.Arena) - @sizeOf(std.mem.Allocator.VTable), arena.data.len, "Wrong arena capacity");
        }

        //test push_bytes_unaligned
        const num_bytes = toolbox.kb(4);
        {
            const bytes = arena.push_bytes_unaligned(num_bytes);
            toolbox.asserteq(num_bytes, bytes.len, "Wrong number of bytes allocated");

            for (bytes) |*b| b.* = 0xFF;
        }
        //test push_slice
        const num_longs = 1024;
        {
            const longs = arena.push_slice(u64, num_longs);
            toolbox.asserteq(num_longs, longs.len, "Wrong number of longs");

            for (longs) |*b| b.* = 0xFFFF_FFFF_FFFF_FFFF;
        }
        //test total_bytes_used and reset
        {
            toolbox.asserteq(num_longs * 8 + num_bytes, arena.total_bytes_used(), "Wrong number of bytes used");
            arena.reset();
            toolbox.asserteq(0, arena.total_bytes_used(), "Arena should be reset");
        }
        //test save points
        {
            const longs = arena.push_slice(u64, num_longs);
            toolbox.asserteq(num_longs * 8, arena.total_bytes_used(), "Wrong number of bytes used");
            toolbox.asserteq(num_longs, longs.len, "Wrong number of longs");
            const save_point = arena.create_save_point();
            defer {
                arena.restore_save_point(save_point);
                toolbox.asserteq(num_longs * 8, arena.total_bytes_used(), "Wrong number of bytes used after restoring save point");
            }
            const longs2 = arena.push_slice(u64, num_longs);
            toolbox.asserteq(num_longs * 8 * 2, arena.total_bytes_used(), "Wrong number of bytes used");
            toolbox.asserteq(num_longs, longs2.len, "Wrong number of longs used");
        }
        //pool allocator
        {
            const POOL_SIZE = 8;
            var pool_allocator = toolbox.PoolAllocator(i32).init(POOL_SIZE, arena);
            var ptrs: [POOL_SIZE * 2]*i32 = undefined;
            {
                var i: usize = 0;
                while (i < POOL_SIZE) : (i += 1) {
                    ptrs[i] = pool_allocator.alloc();
                }
            }
            {
                pool_allocator.free(ptrs[3]);
                ptrs[3] = pool_allocator.alloc();

                pool_allocator.free(ptrs[7]);
                pool_allocator.free(ptrs[6]);
                ptrs[6] = pool_allocator.alloc();
                ptrs[7] = pool_allocator.alloc();
            }
        }

        arena.free_all();
    }

    var arena = toolbox.Arena.init(toolbox.mb(1));
    defer arena.free_all();
    //Linked list queue
    {
        defer arena.reset();
        var list = toolbox.LinkedListQueue(i64).init(arena);
        const first_element = list.push(42);
        toolbox.assert(list.len == 1, "List should be length 1", .{});
        toolbox.assert(first_element.* == 42, "Node should have a value of 42", .{});
        toolbox.assert(&list.head.?.value == first_element, "List head should be the same as the first node", .{});
        toolbox.assert(&list.tail.?.value == first_element, "List tail should be the same as its only node", .{});

        const second_element = list.push(42 * 2);
        _ = list.push(42 * 3);

        toolbox.assert(list.len == 3, "List should be length 3", .{});
        toolbox.assert(&list.head.?.value == first_element, "List head should be the same as the first node", .{});

        {
            var i: i64 = 1;
            var it = list.iterator();
            while (it.next()) |value| {
                toolbox.assert(
                    value.* == 42 * i,
                    "Value for linked list node is wrong. Expected: {}, Actual: {} ",
                    .{ 42 * i, value.* },
                );
                i += 1;
            }
        }

        const last_value = list.pop();
        toolbox.assert(last_value == 42 * 1, "Pop gave wrong value", .{});
        toolbox.assert(&list.head.?.value == second_element, "first_element should be removed", .{});
        toolbox.assert(list.len == 2, "List should be length 2 after removal", .{});

        list.clear();
        toolbox.assert(list.len == 0 and list.head == null and list.tail == null, "clear list didn't clear", .{});
    }

    //Linked list stack
    {
        var list = toolbox.LinkedListStack(i64).init(arena);
        _ = list.push(42 * 1);
        _ = list.push(42 * 2);
        _ = list.push(42 * 3);
        {
            var i: i64 = 3;
            var it = list.iterator();
            while (it.next()) |value| {
                toolbox.assert(
                    value.* == 42 * i,
                    "Value for linked list node is wrong. Expected: {}, Actual: {} ",
                    .{ 42 * i, value.* },
                );
                i -= 1;
            }
        }
    }

    //Random removal Linked list
    {
        defer arena.reset();
        var list = toolbox.RandomRemovalLinkedList(i64).init(arena);
        const first_element = list.append(42);
        toolbox.assert(list.len == 1, "List should be length 1", .{});
        toolbox.assert(first_element.* == 42, "Node should have a value of 42", .{});
        toolbox.assert(&list.head.?.value == first_element, "List head should be the same as the first node", .{});
        toolbox.assert(&list.tail.?.value == first_element, "List tail should be the same as its only node", .{});

        const second_element = list.append(42 * 2);
        const third_element = list.append(42 * 3);

        toolbox.assert(list.len == 3, "List should be length 3", .{});
        toolbox.assert(second_element.* == 42 * 2, "Second element is wrong value", .{});
        toolbox.assert(third_element.* == 42 * 3, "Third element is wrong value", .{});
        toolbox.assert(&list.head.?.value == first_element, "List head should be the same as the first node", .{});

        {
            var i: i64 = 1;
            var it = list.iterator();
            while (it.next()) |value| {
                toolbox.assert(
                    value.* == 42 * i,
                    "Value for linked list node is wrong. Expected: {}, Actual: {} ",
                    .{ 42 * i, value.* },
                );
                i += 1;
            }
        }

        list.remove(second_element);
        toolbox.assert(list.len == 2, "List should be length 2", .{});
        {
            var i: i64 = 1;
            var it = list.iterator();
            while (it.next()) |value| {
                toolbox.assert(
                    value.* == 42 * i,
                    "Value for linked list node is wrong. Expected: {}, Actual: {} ",
                    .{ 42 * i, value.* },
                );
                i += 2;
            }
        }

        const zeroth_element = list.prepend(42 * 0);
        toolbox.assert(list.len == 3, "List should be length 3", .{});
        toolbox.assert(zeroth_element.* == 42 * 0, "0th element is wrong value", .{});
        {
            var i: i64 = 0;
            var it = list.iterator();
            while (it.next()) |value| {
                toolbox.assert(
                    value.* == 42 * i,
                    "Value for linked list node is wrong. Expected: {}, Actual: {} ",
                    .{ 42 * i, value.* },
                );
                i += 1;
                if (i == 2) {
                    i = 3;
                }
            }
        }
    }
    //Hash map
    {
        defer arena.reset();
        var map = toolbox.HashMap([]const u8, i64).init(2, arena);
        map.put("Macs", 123);
        map.put("Apple IIs", 432);
        map.put("PCs", 8765);

        var data = map.get("Blah");
        toolbox.asserteq(null, data, "Hash map retrieval is wrong!");
        data = map.get("Macs");
        toolbox.asserteq(123, data.?, "Hash map retrieval is wrong!");
        data = map.get("Apple IIs");
        toolbox.asserteq(432, data.?, "Hash map retrieval is wrong!");
        data = map.get("PCs");
        toolbox.asserteq(8765, data.?, "Hash map retrieval is wrong!");

        map.put("PCs", 87654);
        data = map.get("PCs");
        toolbox.assert(data.? == 87654, "Hash map retrieval is wrong! Expected: {}, Got: {any}", .{ 87654, data });

        toolbox.assert(map.len() == 3, "Hash map len is wrong! Expected: {}, Got: {}", .{ 3, map.len() });
        map.remove("PCs");
        data = map.get("PCs");
        toolbox.asserteq(null, data, "Hash map retrieval is wrong!");
        toolbox.asserteq(2, map.len(), "Hash map len is wrong!");

        data = map.get("Garbage");
        toolbox.asserteq(null, data, "Hash map retrieval is wrong!");

        //collision keys
        map.put("GReLUrM4wMqfg9yzV3KQ", 654);
        map.put("8yn0iYCKYHlIj4-BwPqk", 234);
        data = map.get("GReLUrM4wMqfg9yzV3KQ");
        toolbox.asserteq(654, data.?, "Hash map retrieval is wrong!");
        data = map.get("8yn0iYCKYHlIj4-BwPqk");
        toolbox.asserteq(234, data.?, "Hash map retrieval is wrong!");

        map.remove("GReLUrM4wMqfg9yzV3KQ");
        toolbox.asserteq(3, map.len(), "Hash map len is wrong!");
        data = map.get("GReLUrM4wMqfg9yzV3KQ");
        toolbox.asserteq(null, data, "Hash map retrieval is wrong!");
        data = map.get("8yn0iYCKYHlIj4-BwPqk");
        toolbox.asserteq(234, data.?, "Hash map retrieval is wrong!");
    }

    //numerial hashmap
    {
        defer arena.reset();

        var map = toolbox.HashMap(i64, i64).init(2, arena);
        map.put(123, 123);
        map.put(432, 432);
        map.put(456, 8765);

        var data = map.get(543);
        toolbox.asserteq(null, data, "Hash map retrieval is wrong!");
        data = map.get(123);
        toolbox.asserteq(123, data.?, "Hash map retrieval is wrong!");
        data = map.get(432);
        toolbox.asserteq(432, data.?, "Hash map retrieval is wrong!");
        data = map.get(456);
        toolbox.asserteq(8765, data.?, "Hash map retrieval is wrong!");
    }
    //numerial hashmap
    {
        defer arena.reset();
        var keys = [_]i64{ 123, 432, 456, 6543 };

        var map = toolbox.HashMap(*const i64, i64).init(2, arena);
        map.put(&keys[0], 123);
        map.put(&keys[1], 432);
        map.put(&keys[2], 8765);

        keys[0] = 0;
        keys[1] = 0;
        keys[2] = 0;

        var data = map.get(&keys[3]);
        toolbox.asserteq(null, data, "Hash map retrieval is wrong!");
        data = map.get(&keys[0]);
        toolbox.asserteq(123, data.?, "Hash map retrieval is wrong!");
        data = map.get(&keys[1]);
        toolbox.asserteq(432, data.?, "Hash map retrieval is wrong!");
        data = map.get(&keys[2]);
        toolbox.asserteq(8765, data.?, "Hash map retrieval is wrong!");
    }
    //string
    {
        const english = toolbox.str8lit("Hello!");
        const korean = toolbox.str8lit("안녕하세요!");
        const japanese = toolbox.str8lit("こんにちは!");

        const buffer = [_]u8{ 'H', 'e', 'l', 'l', 'o', '!' };
        const runtime_english = toolbox.str8(buffer[0..]);
        toolbox.asserteq(6, english.rune_length, "Wrong rune length");
        toolbox.asserteq(6, runtime_english.rune_length, "Wrong rune length");
        toolbox.asserteq(6, korean.rune_length, "Wrong rune length");
        toolbox.asserteq(6, japanese.rune_length, "Wrong rune length");

        {
            var it = japanese.iterator();
            var i: usize = 0;
            while (it.next()) |rune_and_length| {
                const rune = rune_and_length.rune;
                const expected: toolbox.Rune = switch (i) {
                    0 => 'こ',
                    1 => 'ん',
                    2 => 'に',
                    3 => 'ち',
                    4 => 'は',
                    5 => '!',
                    else => toolbox.panic("Wrong number of runes!", .{}),
                };
                i += 1;
                toolbox.asserteq(expected, rune, "Wrong rune!");
            }
        }

        //substring
        {
            const s = toolbox.str8lit("hello!");
            const ss = s.substring(1, 3);
            toolbox.asserteq(2, ss.rune_length, "Wrong rune length");
            toolbox.asserteq(2, ss.bytes.len, "Wrong byte length");
            toolbox.asserteq(ss.bytes[0], 'e', "Wrong char at index 0");
            toolbox.asserteq(ss.bytes[1], 'l', "Wrong char at index 1");
        }

        //contains
        {
            const s = toolbox.str8lit("hello!");
            const substring = toolbox.str8lit("ll");
            const not_substring1 = toolbox.str8lit("ll!");
            const not_substring2 = toolbox.str8lit("hello!!!!");

            toolbox.asserteq(s.contains(substring), true, "Should contain");
            toolbox.asserteq(s.contains(not_substring1), false, "Should not contain");
            toolbox.asserteq(s.contains(not_substring2), false, "Should not contain");
        }
    }
    //stack
    //TODO
    {}
    //ring queue
    {
        defer arena.reset();
        var ring_queue = toolbox.RingQueue(i64).init(8, arena);
        for (0..10) |u| {
            const i = @as(i64, @intCast(u));
            ring_queue.force_enqueue(i);
        }
        var it = ring_queue.iterator();
        var expected: i64 = 3;
        while (it.next()) |got| {
            toolbox.assert(
                expected == got,
                "Unexpected ring queue value.  Expected: {}, Got: {}",
                .{ expected, got },
            );
            expected += 1;
        }
    }
    //concurrent ring queue single thread test
    {
        defer arena.reset();
        var ring_queue = toolbox.SingleProducerMultiConsumerRingQueue(i64).init(8, arena);
        for (0..10) |u| {
            const i = @as(i64, @intCast(u));
            ring_queue.force_enqueue(i);
        }
        var expected: i64 = 3;
        while (ring_queue.dequeue()) |got| {
            toolbox.assert(
                expected == got,
                "Unexpected ring queue value.  Expected: {}, Got: {}",
                .{ expected, got },
            );
            expected += 1;
        }
    }
    //concurrent ring queue multi thread test
    {
        defer arena.reset();
        var ring_queue = toolbox.SingleProducerMultiConsumerRingQueue(i64).init(8, arena);
        var running = true;
        const enqueue_thread = try std.Thread.spawn(.{}, concurrent_queue_enqueue_test_loop, .{ &ring_queue, &running });
        const dequeue_thread_1 = try std.Thread.spawn(.{}, concurrent_queue_dequeue_test_loop, .{ &ring_queue, &running });
        const dequeue_thread_2 = try std.Thread.spawn(.{}, concurrent_queue_dequeue_test_loop, .{ &ring_queue, &running });

        enqueue_thread.join();
        dequeue_thread_1.join();
        dequeue_thread_2.join();
    }
    toolbox.println("\nAll tests passed!", .{});
}
fn concurrent_queue_enqueue_test_loop(ring_queue: *toolbox.SingleProducerMultiConsumerRingQueue(i64), running: *bool) void {
    for (0..10000) |u| {
        const i = @as(i64, @intCast(u));
        while (!ring_queue.enqueue(i)) {
            std.atomic.spinLoopHint();
        }
    }
    running.* = false;
}
fn concurrent_queue_dequeue_test_loop(ring_queue: *toolbox.SingleProducerMultiConsumerRingQueue(i64), running: *bool) void {
    var last_actual: i64 = -1;
    while (running.*) {
        if (ring_queue.dequeue()) |actual| {
            toolbox.assert(
                actual > last_actual,
                "Unexpected ring queue value.  Expected greater than: {}, Was: {}",
                .{ last_actual, actual },
            );
            last_actual = actual;
        } else {
            std.atomic.spinLoopHint();
        }
    }
}

fn run_benchmarks() void {
    var arena = toolbox.Arena.init(toolbox.mb(16));
    profiler.start_profiler();
    defer {
        profiler.end_profiler();
        const stats = profiler.compute_statistics_of_current_state(arena);
        toolbox.println("Total time: {}ms", .{stats.total_elapsed.milliseconds()});
        for (stats.section_statistics.items()) |to_print| {
            toolbox.println_str8(to_print.str8(arena));
        }
        arena.free_all();
    }

    benchmark("is_iterable", IterableBenchmark{}, arena);
    benchmark("allocate, touch and free memory with OS allocator", OSAllocateBenchmark{}, arena);

    {
        const save_point = arena.create_save_point();
        defer arena.restore_save_point(save_point);
        const new_arena = arena.create_arena_from_arena(toolbox.mb(8));
        var arena_benchmark = ArenaAllocateBenchmark{};
        benchmark("allocate, touch and free memory with arena", &arena_benchmark, new_arena);
        // arena.reset();
    }
    {
        {
            var list = toolbox.LinkedListQueue(i64).init(arena);
            var llpq = LinkedListQueuePushBenchmark{ .list = &list };
            benchmark("LinkedListDeque push", &llpq, arena);
            var llpop = LinkedListQueuePopBenchmark{ .list = &list };
            benchmark("LinkedListDeque pop", &llpop, arena);
        }
        {
            var list = toolbox.LinkedListStack(i64).init(arena);
            var llps = LinkedListStackPushBenchmark{ .list = &list };
            benchmark("LinkedListStack push", &llps, arena);
            var llpop = LinkedListStackPopBenchmark{ .list = &list };
            benchmark("LinkedListStack pop", &llpop, arena);
        }
        // arena.reset();
    }

    //hash map
    {
        {
            var zhmb = ZigHashMapBenchmark{};
            zhmb.map.ensureUnusedCapacity(512) catch |e| {
                toolbox.panic("ensureUnusedCapacity failed: {}", .{e});
            };
            benchmark("Zig HashMap", &zhmb, arena);
            var thmb = ToolboxHashMapBenchmark.init(arena);
            benchmark("Toolbox HashMap", &thmb, arena);
        }

        {
            var zihmb = ZigIntHashMapBenchmark{};
            zihmb.map.ensureUnusedCapacity(512) catch |e| {
                toolbox.panic("ensureUnusedCapacity failed: {}", .{e});
            };
            benchmark("Zig IntHashMap", &zihmb, arena);
            var thimb = ToolboxIntHashMapBenchmark.init(arena);
            benchmark("Toolbox IntHashMap", &thimb, arena);
        }

        {
            var thb = ToolboxHashBenchmark{};
            benchmark("Toolbox Hash", &thb, arena);
            toolbox.println("last hash {x}", .{thb.last_hash});
        }
    }
}

const LinkedListQueuePushBenchmark = struct {
    list: *toolbox.LinkedListQueue(i64),
    fn benchmark(self: *LinkedListQueuePushBenchmark, _: *toolbox.Arena) void {
        _ = self.list.push(2);
    }
};
const LinkedListQueuePopBenchmark = struct {
    list: *toolbox.LinkedListQueue(i64),
    fn benchmark(self: *LinkedListQueuePopBenchmark, _: *toolbox.Arena) void {
        _ = self.list.pop();
    }
};
const LinkedListStackPopBenchmark = struct {
    list: *toolbox.LinkedListStack(i64),
    fn benchmark(self: *LinkedListStackPopBenchmark, _: *toolbox.Arena) void {
        _ = self.list.pop();
    }
};
const LinkedListStackPushBenchmark = struct {
    list: *toolbox.LinkedListStack(i64),
    fn benchmark(self: *LinkedListStackPushBenchmark, _: *toolbox.Arena) void {
        _ = self.list.push(20);
    }
};
const IterableBenchmark = struct {
    fn benchmark(_: *const IterableBenchmark, _: *toolbox.Arena) void {
        _ = toolbox.is_iterable("This is iterable!");
    }
};
const OSAllocateBenchmark = struct {
    fn benchmark(_: *const OSAllocateBenchmark, _: *toolbox.Arena) void {
        const memory = toolbox.os_allocate_memory(toolbox.mb(4));
        memory[0x135] = 0xFF;
        toolbox.os_free_memory(memory);
    }
};
const ArenaAllocateBenchmark = struct {
    fn benchmark(_: *ArenaAllocateBenchmark, arena: *toolbox.Arena) void {
        const memory = arena.push_slice(u8, toolbox.mb(4));
        memory[0x135] = 0xFF;
        arena.reset();
    }
};
const ZigHashMapBenchmark = struct {
    map: std.StringHashMap(i64) = std.StringHashMap(i64).init(std.heap.page_allocator),

    fn benchmark(self: *ZigHashMapBenchmark, _: *toolbox.Arena) void {
        const kv = .{
            "hello",                12345,
            "yes",                  6543,
            "no",                   98765,
            "burger",               7654,
            "test",                 345,
            "GReLUrM4wMqfg9yzV3KQ", 6543,
            "8yn0iYCKYHlIj4-BwPqk", 4567,
        };
        comptime var i = 0;
        inline while (i < kv.len) : (i += 2) {
            const key: []const u8 = kv[i];
            var v = self.map.get(key) orelse kv[i + 1];
            v += 1;
            self.map.put(key, v) catch |e| {
                toolbox.panic("Error putting into map: {}", .{e});
            };
        }
    }
};
const ToolboxHashMapBenchmark = struct {
    map: toolbox.HashMap(toolbox.String8, i64),

    fn init(arena: *toolbox.Arena) ToolboxHashMapBenchmark {
        return ToolboxHashMapBenchmark{
            .map = toolbox.HashMap(toolbox.String8, i64).init(512, arena),
        };
    }

    const s8 = toolbox.str8lit;
    fn benchmark(self: *ToolboxHashMapBenchmark, _: *toolbox.Arena) void {
        const kv = .{
            s8("hello"),                12345,
            s8("yes"),                  6543,
            s8("no"),                   98765,
            s8("burger"),               7654,
            s8("test"),                 345,
            s8("GReLUrM4wMqfg9yzV3KQ"), 6543,
            s8("8yn0iYCKYHlIj4-BwPqk"), 4567,
        };
        comptime var i = 0;
        inline while (i < kv.len) : (i += 2) {
            const key = kv[i];
            var v = self.map.get(key) orelse kv[i + 1];
            v += 1;
            self.map.put(key, v);
        }
    }
};
const ZigIntHashMapBenchmark = struct {
    map: std.AutoHashMap(i64, i64) = std.AutoHashMap(i64, i64).init(std.heap.page_allocator),

    fn benchmark(self: *ZigIntHashMapBenchmark, _: *toolbox.Arena) void {
        const kv = .{
            543232,   12345,
            68495,    6543,
            76453423, 98765,
            1234567,  7654,
            76543,    345,
            49309428, 6543,
        };
        comptime var i = 0;
        inline while (i < kv.len) : (i += 2) {
            const key = kv[i];
            var v = self.map.get(key) orelse kv[i + 1];
            v += 1;
            self.map.put(key, v) catch |e| {
                toolbox.panic("Error putting into map: {}", .{e});
            };
        }
    }
};
const ToolboxIntHashMapBenchmark = struct {
    map: toolbox.HashMap(i64, i64),

    fn init(arena: *toolbox.Arena) ToolboxIntHashMapBenchmark {
        return ToolboxIntHashMapBenchmark{
            .map = toolbox.HashMap(i64, i64).init(512, arena),
        };
    }
    fn benchmark(self: *ToolboxIntHashMapBenchmark, _: *toolbox.Arena) void {
        const kv = .{
            543232,   12345,
            68495,    6543,
            76453423, 98765,
            1234567,  7654,
            76543,    345,
            49309428, 6543,
        };
        comptime var i = 0;
        inline while (i < kv.len) : (i += 2) {
            const key = kv[i];
            var v = self.map.get(key) orelse kv[i + 1];
            v += 1;
            self.map.put(key, v);
        }
    }
};
const ToolboxHashBenchmark = struct {
    last_hash: u64 = 0,
    fn benchmark(self: *ToolboxHashBenchmark, _: *toolbox.Arena) void {
        const k = .{
            "hello",
            "yes",
            "no",
            "burger",
            "test",
        };
        comptime var i = 0;
        inline while (i < k.len) : (i += 1) {
            self.last_hash = toolbox.hash_fnv1a64(k[i]);
        }
    }
};

pub fn benchmark(comptime benchmark_name: []const u8, benchmark_obj: anytype, arena: *toolbox.Arena) void {
    const total_iterations = 1000;
    {
        for (0..total_iterations) |_| {
            profiler.begin(benchmark_name);
            benchmark_obj.benchmark(arena);
            profiler.end();
        }
    }
}

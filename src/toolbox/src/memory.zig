const toolbox = @import("toolbox.zig");
const std = @import("std");
const root = @import("root");

pub const z = std.mem.zeroes;

pub const PAGE_SIZE = switch (toolbox.THIS_PLATFORM) {
    .MacOS => toolbox.kb(16),
    .UEFI => toolbox.kb(4),
    .Playdate => 4, //Playdate is embeded, so no concept of pages, but everything should be 4-byte aligned
    .BoksOS, .Wozmon64 => toolbox.mb(2),
    .WASM => toolbox.kb(64),
};

pub fn PoolAllocator(comptime T: type) type {
    return struct {
        elements: []Element,
        next_index: usize = 0,
        elements_allocated: usize = 0,

        const Self = @This();
        const Element = struct {
            data: T = undefined,
            in_use: bool = false,
        };

        pub fn init(number_of_elements: usize, arena: *Arena) PoolAllocator(T) {
            const ret = PoolAllocator(T){
                .elements = arena.push_slice_clear(Element, number_of_elements),
            };
            return ret;
        }

        pub fn alloc(self: *Self) *T {
            const start = self.next_index;
            var element = &self.elements[self.next_index];
            while (element.in_use) {
                self.next_index += 1;
                self.next_index %= self.elements.len;
                element = &self.elements[self.next_index];

                if (self.next_index == start) {
                    toolbox.panic("Pool allocator is full!", .{});
                }
            }
            element.in_use = true;
            if (comptime toolbox.IS_DEBUG) {
                const to_alloc_address = @intFromPtr(&element.data);
                const elements_address = @intFromPtr(self.elements.ptr);
                toolbox.assert(
                    to_alloc_address >= elements_address and to_alloc_address < elements_address + self.elements.len * @sizeOf(Element),
                    "Invalid address of element to allocate: {x}. Element pool address: {x}",
                    .{ to_alloc_address, elements_address },
                );
            }

            self.elements_allocated += 1;

            return &element.data;
        }

        pub fn free(self: *Self, to_free: *T) void {
            if (comptime toolbox.IS_DEBUG) {
                const to_free_address = @intFromPtr(to_free);
                const elements_address = @intFromPtr(self.elements.ptr);
                toolbox.assert(
                    to_free_address >= elements_address and to_free_address < elements_address + self.elements.len * @sizeOf(Element),
                    "Invalid address of element to free: {x}. Element pool address: {x}",
                    .{ to_free_address, elements_address },
                );
            }
            var element: *Element = @fieldParentPtr("data", to_free);
            element.in_use = false;
            self.elements_allocated -= 1;
        }
    };
}
pub const Arena = struct {
    data: []u8,

    pos: usize = 0,
    to_free: ?[]u8 = null,

    save_points: [64]SavePoint = [_]SavePoint{0} ** 64,
    current_save: usize = 0,
    zstd_allocator: std.mem.Allocator,

    pub const SavePoint = usize;

    pub const ZSTD_VTABLE = std.mem.Allocator.VTable{
        .alloc = zstd_alloc,
        .resize = zstd_resize,
        .free = zstd_free,
        .remap = zstd_remap,
    };

    pub fn init(comptime size: usize) *Arena {
        comptime {
            if (size < PAGE_SIZE) {
                @compileError("Arena size must be at least the size of a page!");
            }
            if (!toolbox.is_power_of_2(size)) {
                @compileError("Arena size must be a power of 2!");
            }
        }
        const data = os_allocate_memory(size);
        var tmp_arena = Arena{
            .data = data,
            .pos = 0,
            .zstd_allocator = undefined,
        };
        const ret = tmp_arena.push(Arena);
        const zstd_allocator = tmp_arena.create_zstd_allocator();
        ret.* = .{
            .data = data[tmp_arena.pos..],
            .to_free = data,
            .zstd_allocator = zstd_allocator,
        };
        return ret;
    }
    pub fn init_with_buffer(buffer: []u8) *Arena {
        if (!toolbox.is_power_of_2(buffer.len)) {
            toolbox.panic("Arena size must be a power of 2! But was: {}", .{buffer.len});
        }
        var tmp_arena = Arena{
            .data = buffer,
            .pos = 0,
            .zstd_allocator = undefined,
        };
        const ret = tmp_arena.push(Arena);
        const zstd_allocator = tmp_arena.create_zstd_allocator();
        ret.* = .{
            .data = buffer[tmp_arena.pos..],
            .zstd_allocator = zstd_allocator,
        };

        return ret;
    }

    pub fn save(self: *Arena) void {
        toolbox.assert(self.current_save < self.save_points.len, "Too many save points in arena", .{});
        const save_point = self.create_save_point();
        self.save_points[self.current_save] = save_point;
        self.current_save += 1;
    }

    pub fn restore(self: *Arena) void {
        toolbox.assert(self.current_save > 0, "Restored without save point", .{});
        self.restore_save_point(self.save_points[self.current_save]);
        self.current_save -= 1;
    }

    pub fn create_arena_from_arena(self: *Arena, comptime size: usize) *Arena {
        comptime {
            if (!toolbox.is_power_of_2(size)) {
                @compileError("Arena size must be a power of 2!");
            }
        }
        const data = self.push_bytes_unaligned(size);
        return init_with_buffer(data);
    }

    pub inline fn push(self: *Arena, comptime T: type) *T {
        return self.push_single(T, false, @alignOf(T));
    }
    pub inline fn push_aligned(self: *Arena, comptime T: type, comptime alignment: usize) *align(alignment) T {
        return self.push_single(T, false, alignment);
    }
    pub inline fn push_clear(self: *Arena, comptime T: type) *T {
        return self.push_single(T, true, @alignOf(T));
    }
    pub inline fn push_clear_aligned(self: *Arena, comptime T: type, comptime alignment: usize) *align(alignment) T {
        return self.push_single(T, true, alignment);
    }
    pub inline fn push_slice(self: *Arena, comptime T: type, n: usize) []T {
        return self.push_multiple(T, n, false, @alignOf(T));
    }
    pub inline fn push_slice_aligned(self: *Arena, comptime T: type, n: usize, comptime alignment: usize) []align(alignment) T {
        return self.push_multiple(T, n, false, alignment);
    }
    pub inline fn push_slice_clear(self: *Arena, comptime T: type, n: usize) []T {
        return self.push_multiple(T, n, true, @alignOf(T));
    }
    pub inline fn push_slice_clear_aligned(self: *Arena, comptime T: type, n: usize, comptime alignment: usize) []align(alignment) T {
        return self.push_multiple(T, n, true, alignment);
    }
    pub fn push_bytes_unaligned(arena: *Arena, n: usize) []u8 {
        if (arena.data.len - arena.pos >= n) {
            const ret = arena.data[arena.pos .. arena.pos + n];
            arena.pos += n;
            toolbox.assert(arena.pos <= arena.data.len, "Arena position is bad!", .{});
            return ret;
        }

        toolbox.panic("Arena allocation request is too large. {} bytes", .{n});
    }
    pub fn push_bytes_aligned(arena: *Arena, n: usize, comptime alignment: usize) []align(alignment) u8 {
        const data_address = @intFromPtr(arena.data.ptr);
        const aligned_address = toolbox.align_up(arena.pos + data_address, alignment);
        const aligned_pos = aligned_address - data_address;
        const total_size = (aligned_pos - arena.pos) + n;
        if (arena.data.len - aligned_pos >= total_size) {
            const ret: []align(alignment) u8 = @alignCast(arena.data[aligned_pos .. aligned_pos + n]);
            arena.pos += total_size;
            toolbox.assert(toolbox.is_aligned_to(@intFromPtr(ret.ptr), alignment), "Alignment of return value is wrong!", .{});
            toolbox.assert(arena.pos <= arena.data.len, "Arena position is bad!", .{});
            return ret;
        }
        toolbox.panic("Arena allocation request is too large. {} bytes", .{n});
    }

    pub fn push_bytes_aligned_runtime(arena: *Arena, n: usize, alignment: usize) []u8 {
        const data_address = @intFromPtr(arena.data.ptr);
        const aligned_address = toolbox.align_up(arena.pos + data_address, alignment);
        const aligned_pos = aligned_address - data_address;
        const total_size = (aligned_pos - arena.pos) + n;
        if (arena.data.len - aligned_pos >= total_size) {
            const ret: []u8 = arena.data[aligned_pos .. aligned_pos + n];
            arena.pos += total_size;
            toolbox.assert(arena.pos <= arena.data.len, "Arena position is bad!", .{});
            return ret;
        }
        toolbox.panic("Arena allocation request is too large. {} bytes", .{n});
    }

    fn create_zstd_allocator(self: *Arena) std.mem.Allocator {
        const vtable = self.push(std.mem.Allocator.VTable);
        vtable.* = ZSTD_VTABLE;
        return .{
            .ptr = self,
            .vtable = vtable,
        };
    }
    /// Attempt to allocate exactly `len` bytes aligned to `1 << ptr_align`.
    ///
    /// `ret_addr` is optionally provided as the first return address of the
    /// allocation call stack. If the value is `0` it means no return address
    /// has been provided.
    fn zstd_alloc(ctx: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const ShiftSize = if (comptime @sizeOf(usize) == 8) u6 else u5;

        _ = ret_addr;
        const self: *toolbox.Arena = @ptrCast(@alignCast(ctx));

        const alignment = @as(usize, 1) << @as(ShiftSize, @intFromEnum(ptr_align));
        return self.push_bytes_aligned_runtime(len, alignment).ptr;
    }

    /// Attempt to expand or shrink memory in place. `buf.len` must equal the
    /// length requested from the most recent successful call to `alloc` or
    /// `resize`. `buf_align` must equal the same value that was passed as the
    /// `ptr_align` parameter to the original `alloc` call.
    ///
    /// A result of `true` indicates the resize was successful and the
    /// allocation now has the same address but a size of `new_len`. `false`
    /// indicates the resize could not be completed without moving the
    /// allocation to a different address.
    ///
    /// `new_len` must be greater than zero.
    ///
    /// `ret_addr` is optionally provided as the first return address of the
    /// allocation call stack. If the value is `0` it means no return address
    /// has been provided.
    fn zstd_resize(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        _ = ret_addr;
        _ = buf_align;
        _ = ctx;
        if (new_len <= buf.len) {
            return true;
        }

        return false;
    }

    /// Attempt to expand or shrink memory, allowing relocation.
    ///
    /// `memory.len` must equal the length requested from the most recent
    /// successful call to `alloc`, `resize`, or `remap`. `alignment` must
    /// equal the same value that was passed as the `alignment` parameter to
    /// the original `alloc` call.
    ///
    /// A non-`null` return value indicates the resize was successful. The
    /// allocation may have same address, or may have been relocated. In either
    /// case, the allocation now has size of `new_len`. A `null` return value
    /// indicates that the resize would be equivalent to allocating new memory,
    /// copying the bytes from the old memory, and then freeing the old memory.
    /// In such case, it is more efficient for the caller to perform the copy.
    ///
    /// `new_len` must be greater than zero.
    ///
    /// `ret_addr` is optionally provided as the first return address of the
    /// allocation call stack. If the value is `0` it means no return address
    /// has been provided.
    pub fn zstd_remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const resized = zstd_resize(ctx, memory, alignment, new_len, ret_addr);
        if (resized) {
            return memory.ptr;
        }

        return null;
    }

    /// Free and invalidate a buffer.
    ///
    /// `buf.len` must equal the most recent length returned by `alloc` or
    /// given to a successful `resize` call.
    ///
    /// `buf_align` must equal the same value that was passed as the
    /// `ptr_align` parameter to the original `alloc` call.
    ///
    /// `ret_addr` is optionally provided as the first return address of the
    /// allocation call stack. If the value is `0` it means no return address
    /// has been provided.
    fn zstd_free(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
        _ = ret_addr;
        _ = buf_align;
        _ = buf;
        _ = ctx;
    }

    fn push_single(
        self: *Arena,
        comptime T: type,
        comptime should_clear: bool,
        comptime alignment: usize,
    ) *align(alignment) T {
        const ret_bytes = self.push_bytes_aligned(@sizeOf(T), alignment);
        if (comptime should_clear) {
            @memset(ret_bytes, 0);
        }
        return @ptrCast(ret_bytes.ptr);
    }
    fn push_multiple(
        self: *Arena,
        comptime T: type,
        n: usize,
        comptime should_clear: bool,
        comptime alignment: usize,
    ) []align(alignment) T {
        const ret_bytes = self.push_bytes_aligned(@sizeOf(T) * n, alignment);
        if (comptime should_clear) {
            @memset(ret_bytes, 0);
        }
        return @as([*]align(alignment) T, @ptrCast(ret_bytes.ptr))[0..n];
    }

    pub fn expand(arena: *Arena, ptr: anytype, new_size: usize) @TypeOf(ptr) {
        const Child = @typeInfo(@TypeOf(ptr)).Pointer.child;
        toolbox.asserteq(
            arena.pos,
            @intFromPtr(arena.data.ptr) + (arena.data.len * @sizeOf(Child)) - @intFromPtr(ptr),
            "Slice to expand must've been last allocation",
        );
        return ptr.ptr[0..new_size];
    }

    pub fn total_bytes_used(arena: *const Arena) usize {
        return arena.pos;
    }

    pub fn create_save_point(arena: *Arena) SavePoint {
        return arena.pos;
    }

    pub fn restore_save_point(arena: *Arena, save_point: SavePoint) void {
        toolbox.assert(save_point <= arena.pos, "Save point should be before arena position", .{});
        arena.pos = save_point;
    }

    pub fn reset(arena: *Arena) void {
        arena.pos = 0;
    }

    pub fn free_all(arena: *Arena) void {
        if (arena.to_free) |data| {
            os_free_memory(data);
        }
    }
};

pub fn os_allocate_object(comptime T: type) *T {
    const memory = platform_allocate_memory(@sizeOf(T));
    return @as(*T, @ptrCast(@alignCast(memory.ptr)));
}
pub fn os_free_object(to_free: anytype) void {
    const object_size = @sizeOf(@TypeOf(to_free.*));
    platform_free_memory(@as([*]u8, @ptrCast(to_free))[0..object_size]);
}
pub fn os_allocate_objects(comptime T: type, n: usize) []T {
    const memory = platform_allocate_memory(n * @sizeOf(T));
    return @as([*]T, @alignCast(memory.ptr))[0..n];
}
pub fn os_free_objects(to_free: anytype) void {
    platform_free_memory(@as(
        [*]u8,
        to_free.ptr,
    )[0 .. to_free.len * @sizeOf(toolbox.child_type(@TypeOf(to_free)))]);
}
pub fn os_allocate_memory(n: usize) []u8 {
    return platform_allocate_memory(n);
}
pub fn os_free_memory(memory: []u8) void {
    return platform_free_memory(memory);
}

///platform functions
const platform_allocate_memory = switch (toolbox.THIS_PLATFORM) {
    //.MacOS => unix_allocate_memory,
    //.MacOS => posix_allocate_memory,
    .MacOS => macos_allocate_memory,
    .Playdate => playdate_allocate_memory,
    .BoksOS, .Wozmon64 => root.allocate_memory,
    .WASM => posix_allocate_memory,
    else => @compileError("OS not supported"),
};
const platform_free_memory = switch (toolbox.THIS_PLATFORM) {
    //.MacOS => unix_free_memory,
    //.MacOS => posix_free_memory,
    .MacOS => macos_free_memory,
    .Playdate => playdate_free_memory,
    .WASM => posix_free_memory,
    .BoksOS, .Wozmon64 => root.free_memory,
    else => @compileError("OS not supported"),
};

///Unix functions
const mman = if (toolbox.THIS_PLATFORM == .MacOS) @cImport(@cInclude("sys/mman.h")) else null;
fn unix_free_memory(memory: []u8) void {
    const code = mman.munmap(memory.ptr, memory.len);
    if (code != 0) {
        toolbox.panic("Error freeing OS memory. Code: {}", .{code});
    }
}
fn unix_allocate_memory(n: usize) []u8 {
    if (mman.mmap(null, n, mman.PROT_READ | mman.PROT_WRITE, mman.MAP_PRIVATE | mman.MAP_ANONYMOUS, -1, 0)) |ptr| {
        if (ptr != mman.MAP_FAILED) {
            return @as([*]u8, ptr)[0..n];
        } else {
            toolbox.panic("Error allocating {} bytes of OS memory", .{n});
        }
    } else {
        toolbox.panic("Error allocating {} bytes of OS memory", .{n});
    }
}

//macOS functions
const VM_FLAGS_ANYWHERE = 1;
const MachPort = u32;
extern var mach_task_self_: MachPort;
extern fn mach_vm_allocate(target: MachPort, address: *u64, size: u64, flags: c_int) c_int;
extern fn mach_vm_deallocate(target: MachPort, address: u64, size: u64) c_int;
fn macos_allocate_memory(n: usize) []u8 {
    var address: u64 = 0;

    const code = mach_vm_allocate(mach_task_self_, &address, n, VM_FLAGS_ANYWHERE);
    if (code == 0) {
        return @as([*]u8, @ptrFromInt(address))[0..n];
    }
    toolbox.panic("Error allocating {} bytes of OS memory. Code: {}", .{ n, code });
}
fn macos_free_memory(memory: []u8) void {
    const code = mach_vm_deallocate(mach_task_self_, @intFromPtr(memory.ptr), memory.len);
    if (code != 0) {
        toolbox.panic("Error freeing OS memory. Code: {}", .{code});
    }
}

//posix functions
extern fn calloc(count: usize, size: usize) ?*anyopaque;
extern fn malloc(n: usize) ?*anyopaque;
//extern fn free(ptr: ?*anyopaque) void;
const c_free = @extern(fn (ptr: ?*anyopaque) void, .{ .name = "free" });
fn posix_allocate_memory(n: usize) []u8 {
    //NOTE: despite what Apple says, calloc is terrible.  Don't use it
    //const data_opt = calloc(1, n);
    const data_opt = malloc(n);
    if (data_opt) |data| {
        return @as([*]u8, @ptrCast(data))[0..n];
    }
    toolbox.panic("Error allocating {} bytes of OS memory.", .{n});
}
fn posix_free_memory(memory: []u8) void {
    c_free(memory.ptr);
}

////Playdate functions
fn playdate_allocate_memory(n: usize) []u8 {
    const data_opt = toolbox.playdate_realloc(null, n);
    if (data_opt) |data| {
        return @as([*]u8, @ptrCast(data))[0..n];
    }
    toolbox.panic("Error allocating {} bytes of OS memory.", .{n});
}
fn playdate_free_memory(memory: []u8) void {
    _ = toolbox.playdate_realloc(memory.ptr, 0);
}

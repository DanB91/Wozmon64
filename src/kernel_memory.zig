const w64 = @import("wozmon64_kernel.zig");
const amd64 = @import("amd64.zig");
const toolbox = @import("toolbox");
const std = @import("std");
const error_log = @import("error_log.zig");

const PageAllocatorState = struct {
    virtual_address_conventional_free_list: FreeList,
    virtual_address_mmio_free_list: FreeList,
    physical_address_conventional_free_list: FreeList,

    physical_address_conventional_pool: []w64.ConventionalMemoryDescriptor,
    next_free_virtual_address: u64,

    arena: *toolbox.Arena,

    zig_std_allocator: std.mem.Allocator,

    lock: w64.ReentrantTicketLock = .{},
};

const FreeList = toolbox.RandomRemovalLinkedList(FreeListEntry);
const FreeListEntry = struct {
    address: u64,
    number_of_pages: usize,
    page_size: usize,
};

var g_state: PageAllocatorState = undefined;

pub fn init(
    arena: *toolbox.Arena,
    physical_address_conventional_pool: []w64.ConventionalMemoryDescriptor,
    next_free_virtual_address: u64,
) void {
    const mem_arena = arena.create_arena_from_arena(toolbox.mb(1));
    const zig_vtable = mem_arena.push(std.mem.Allocator.VTable);
    zig_vtable.* = .{
        .alloc = zig_std_alloc,
        .resize = zig_std_resize,
        .free = zig_std_free,
    };
    g_state = .{
        .virtual_address_conventional_free_list = FreeList.init(mem_arena),
        .virtual_address_mmio_free_list = FreeList.init(mem_arena),
        .physical_address_conventional_free_list = FreeList.init(mem_arena),
        .physical_address_conventional_pool = physical_address_conventional_pool,
        .next_free_virtual_address = next_free_virtual_address,
        .arena = mem_arena,
        .zig_std_allocator = .{
            .ptr = undefined,
            .vtable = zig_vtable,
        },
    };
}
pub fn allocate_conventional_at_address(virtual_address: u64, num_pages: usize) []align(w64.MEMORY_PAGE_SIZE) u8 {
    const virtual_start = virtual_address;
    var virtual_address_cursor = virtual_address;
    const physical_conventional_free_list = &g_state.physical_address_conventional_free_list;
    const page_size = w64.MEMORY_PAGE_SIZE;

    for (0..num_pages) |_| {
        var physical_address =
            search_for_free_address(1, physical_conventional_free_list);
        if (physical_address == 0) {
            physical_address = calculate_next_free_conventional_physical_address(1);
            if (physical_address == 0) {
                toolbox.panic("No more physical memory left kernel!", .{});
            }
        }
        const result = map_conventional(
            virtual_address_cursor,
            physical_address,
        );
        if (!result) {
            toolbox.panic("Unable to map {X} to {X}", .{ virtual_address_cursor, physical_address });
        }
        virtual_address_cursor += page_size;
    }

    return @as(
        [*]align(w64.MEMORY_PAGE_SIZE) u8,
        @ptrFromInt(virtual_start),
    )[0 .. num_pages * page_size];
}
pub fn allocate_conventional(num_pages: usize) []align(w64.MEMORY_PAGE_SIZE) u8 {
    g_state.lock.lock();
    defer g_state.lock.release();

    const page_size = w64.MEMORY_PAGE_SIZE;

    const virtual_address = generate_new_virtual_address(num_pages, page_size);
    if (virtual_address == 0) {
        toolbox.panic("No more virtual address space left in kernel!", .{});
    }

    return allocate_conventional_at_address(virtual_address, num_pages);
}

pub fn map_conventional(virtual_address: u64, physical_address: u64) bool {
    if (!toolbox.is_aligned_to(virtual_address, w64.MEMORY_PAGE_SIZE)) {
        error_log.log_error("Bad alignment for virtual address: {X}", .{virtual_address});
        return false;
    }
    if (!toolbox.is_aligned_to(physical_address, w64.MEMORY_PAGE_SIZE)) {
        error_log.log_error("Bad alignment for physical address: {X}", .{virtual_address});
        return false;
    }

    toolbox.assert(
        virtual_address > 0xFFFF_FF7F_FFFF_FFFF or virtual_address < 0xFFFF_FF80_0000_0000,
        "Mapping page table virtual address! physical address: {x}, virtual_address: {x}",
        .{ virtual_address, physical_address },
    );

    g_state.lock.lock();
    defer g_state.lock.release();

    const arena = g_state.arena;
    const vaddr_bits: amd64.VirtualAddress2MBPage = @bitCast(virtual_address);
    const pdp = b: {
        const pml4t = w64.get_pml4t();
        const entry = &pml4t.entries[vaddr_bits.pml4t_offset];
        if (!entry.present) {
            const pdp = arena.push_clear(amd64.PageDirectoryPointer);
            const page_physical_address = virtual_to_physical(
                @intFromPtr(pdp),
            );
            if (page_physical_address == 0) {
                toolbox.panic("Expected PDP address {X} to be mapped, but was not!", .{@intFromPtr(pdp)});
            }
            entry.* = .{
                .present = true,
                .write_enable = true,
                .ring3_accessible = false,
                .writethrough = false,
                .cache_disable = false,
                .pdp_base_address = @intCast(page_physical_address >> 12),
                .no_execute = true,
            };
            break :b pdp;
        } else {
            break :b w64.get_pdp(virtual_address);
        }
    };
    const pd = b: {
        const entry = &pdp.entries[vaddr_bits.pdp_offset];
        if (!entry.present) {
            const pd = arena.push_clear(amd64.PageDirectory2MB);
            const page_physical_address = virtual_to_physical(
                @intFromPtr(pd),
            );
            if (page_physical_address == 0) {
                toolbox.panic("Expected PD address {X} to be mapped, but was not!", .{@intFromPtr(pd)});
            }
            entry.* = .{
                .present = true,
                .write_enable = true,
                .ring3_accessible = false,
                .writethrough = false,
                .cache_disable = false,
                .pd_base_address = @intCast(page_physical_address >> 12),
                .no_execute = true,
            };
            break :b pd;
        } else {
            break :b w64.get_pd_2mb(virtual_address);
        }
    };
    //Finally map the actual page
    {
        const entry = &pd.entries[vaddr_bits.pd_offset];
        if (!entry.present) {
            entry.* = .{
                .present = true,
                .write_enable = true,
                .ring3_accessible = false,
                .pat_bit_0 = 0, //cachable
                .pat_bit_1 = 0,
                .pat_bit_2 = 0,
                .global = (virtual_address & (1 << 63)) != 0,
                .physical_page_base_address = @intCast(physical_address >> 21),
                .memory_protection_key = 0,
                .no_execute = false,
            };
        } else {
            if (entry.must_be_one != 1) {
                toolbox.panic(
                    "Expected 2MB PD, but was 4KB! Attempted virtual address to map: {X}",
                    .{virtual_address},
                );
            }
            error_log.log_error("Virtual address: {X}. Attempted to map to: {X}, pde: {X}, offset: {}, entry {} PADDR: {X}. PDP: {X}, pdp entry: {}, pdp: offset: {}, PADDR: {X}", .{
                virtual_address,
                physical_address,
                @intFromPtr(entry),
                vaddr_bits.pd_offset,
                entry.*,
                virtual_to_physical(@intFromPtr(pd)),
                @intFromPtr(pdp),
                pdp.entries[vaddr_bits.pdp_offset],
                vaddr_bits.pdp_offset,
                virtual_to_physical(@intFromPtr(pdp)),
            });

            const pml4t = w64.get_pml4t();
            const pml4_entry = &pml4t.entries[vaddr_bits.pml4t_offset];
            error_log.log_error("PML4: {X}, pml4 entry: {}, pml4: offset: {}, PADDR: {X}", .{
                @intFromPtr(pml4t),
                pml4_entry.*,
                vaddr_bits.pml4t_offset,
                virtual_to_physical(@intFromPtr(pml4t)),
            });
            return false;
        }
    }
    return true;
}
pub fn is_valid_2mb_page_virtual_address(virtual_address: u64) bool {
    g_state.lock.lock();
    defer g_state.lock.release();

    const vaddr_bits: amd64.VirtualAddress2MBPage = @bitCast(virtual_address);
    const pdp = b: {
        const pml4t = w64.get_pml4t();
        const entry = pml4t.entries[vaddr_bits.pml4t_offset];
        if (entry.present) {
            break :b w64.get_pdp(virtual_address);
        } else {
            return true;
        }
    };
    const pd = b: {
        const entry = pdp.entries[vaddr_bits.pdp_offset];
        if (entry.present) {
            break :b w64.get_pd_2mb(virtual_address);
        } else {
            return true;
        }
    };

    const pde = pd.entries[vaddr_bits.pd_offset];
    if (pde.present) {
        return pde.must_be_one == 1;
    }
    return true;
}
pub fn map_mmio(virtual_address: u64, physical_address: u64) bool {
    if (!toolbox.is_aligned_to(virtual_address, w64.MMIO_PAGE_SIZE)) {
        error_log.log_error("Bad alignment for virtual address: {X}", .{virtual_address});
        return false;
    }
    if (!toolbox.is_aligned_to(physical_address, w64.MMIO_PAGE_SIZE)) {
        error_log.log_error("Bad alignment for physical address: {X}", .{physical_address});
        return false;
    }

    toolbox.assert(
        virtual_address > 0xFFFF_FF7F_FFFF_FFFF or virtual_address < 0xFFFF_FF80_0000_0000,
        "Mapping page table virtual address! physical address: {x}, virtual_address: {x}",
        .{ virtual_address, physical_address },
    );

    g_state.lock.lock();
    defer g_state.lock.release();

    const arena = g_state.arena;
    const vaddr_bits: amd64.VirtualAddress4KBPage = @bitCast(virtual_address);
    const pdp = b: {
        const pml4t = w64.get_pml4t();
        const entry = &pml4t.entries[vaddr_bits.pml4t_offset];
        if (!entry.present) {
            const pdp = arena.push_clear(amd64.PageDirectoryPointer);
            const page_physical_address = virtual_to_physical(
                @intFromPtr(pdp),
            );
            if (page_physical_address == 0) {
                return false;
            }
            entry.* = .{
                .present = true,
                .write_enable = true,
                .ring3_accessible = false,
                .writethrough = false,
                .cache_disable = false,
                .pdp_base_address = @intCast(page_physical_address >> 12),
                .no_execute = true,
            };
            break :b pdp;
        } else {
            break :b w64.get_pdp(virtual_address);
        }
    };
    const pd = b: {
        const entry = &pdp.entries[vaddr_bits.pdp_offset];
        if (!entry.present) {
            const pd = arena.push_clear(amd64.PageDirectory4KB);
            const page_physical_address = virtual_to_physical(
                @intFromPtr(pd),
            );
            if (page_physical_address == 0) {
                return false;
            }
            entry.* = .{
                .present = true,
                .write_enable = true,
                .ring3_accessible = false,
                .writethrough = false,
                .cache_disable = false,
                .pd_base_address = @intCast(page_physical_address >> 12),
                .no_execute = true,
            };
            break :b pd;
        } else {
            break :b w64.get_pd_4kb(virtual_address);
        }
    };
    const pt = b: {
        const entry = &pd.entries[vaddr_bits.pd_offset];
        if (!entry.present) {
            const pt = arena.push_clear(amd64.PageTable);
            const page_physical_address = virtual_to_physical(
                @intFromPtr(pt),
            );
            if (page_physical_address == 0) {
                return false;
            }
            entry.* = .{
                .present = true,
                .write_enable = true,
                .ring3_accessible = false,
                .writethrough = false,
                .cache_disable = false,
                .pt_base_address = @intCast(page_physical_address >> 12),
                .no_execute = true,
            };
            break :b pt;
        } else {
            toolbox.assert(
                entry.must_be_zero == 0,
                "Expected 4KB PD, but was 2MB! Attempted virtual address to map: {X}",
                .{virtual_address},
            );
            break :b w64.get_pt(virtual_address);
        }
    };
    //Finally map the actual page
    {
        const entry = &pt.entries[vaddr_bits.pt_offset];
        if (!entry.present) {
            entry.* = .{
                .present = true,
                .write_enable = true,
                .ring3_accessible = false,
                .pat_bit_0 = 1, //uncachable
                .pat_bit_1 = 1,
                .pat_bit_2 = 0,
                .global = true,
                .physical_page_base_address = @intCast(physical_address >> 12),
                .memory_protection_key = 0,
                .no_execute = true,
            };
        } else {
            error_log.log_error("Virtual address: {X} already mapped.", .{virtual_address});
            return false;
        }
    }
    return true;
}
pub fn free_conventional(data: []align(w64.MEMORY_PAGE_SIZE) u8) void {
    g_state.lock.lock();
    defer g_state.lock.release();

    const virtual_conventional_free_list = &g_state.virtual_address_conventional_free_list;
    const physical_conventional_free_list = &g_state.physical_address_conventional_free_list;

    const num_pages = data.len / w64.MEMORY_PAGE_SIZE;
    const virtual_start = @intFromPtr(data.ptr);
    var virtual_address = virtual_start;

    for (0..num_pages) |_| {
        const physical_address = unmap(virtual_address);
        virtual_address += w64.MEMORY_PAGE_SIZE;
        if (physical_address != 0) {
            _ = physical_conventional_free_list.prepend(.{
                .address = physical_address,
                .number_of_pages = 1,
                .page_size = w64.MEMORY_PAGE_SIZE,
            });
        }
    }
    _ = virtual_conventional_free_list.prepend(.{
        .address = virtual_start,
        .number_of_pages = 1,
        .page_size = w64.MEMORY_PAGE_SIZE,
    });
}
pub fn pages_free() usize {
    g_state.lock.lock();
    defer g_state.lock.release();

    var ret: usize = 0;
    for (g_state.physical_address_conventional_pool) |desc| {
        ret += desc.number_of_pages;
    }
    var it = g_state.physical_address_conventional_free_list.iterator();
    while (it.next()) |block| {
        ret += block.number_of_pages;
    }
    return ret;
}

pub fn unmap(virtual_address: u64) u64 {
    g_state.lock.lock();
    defer g_state.lock.release();

    {
        const vaddr_2mb: amd64.VirtualAddress2MBPage = @bitCast(virtual_address);
        var pd_entry_2mb: *volatile amd64.PageDirectoryEntry2MB =
            &w64.get_pd_2mb(virtual_address).entries[vaddr_2mb.pd_offset];
        if (!pd_entry_2mb.present) {
            error_log.log_error("Cannot unmap: {X} due to pd_entry_2mb not being present", .{virtual_address});
            return 0;
        }

        //is it actually a 2MB page?
        if (pd_entry_2mb.must_be_one == 1) {
            pd_entry_2mb.present = false;
            asm volatile (
                \\invlpg (%[virtual_address])
                :
                : [virtual_address] "r" (virtual_address),
                : "memory"
            );
            return @as(u64, pd_entry_2mb.physical_page_base_address) << 21;
        }
    }

    //It is a 4KB page
    {
        const vaddr_4kb: amd64.VirtualAddress4KBPage = @bitCast(virtual_address);
        var pt_entry: *volatile amd64.PageTableEntry = &w64.get_pt(virtual_address).entries[vaddr_4kb.pt_offset];
        pt_entry.present = false;
        asm volatile (
            \\invlpg (%[virtual_address])
            :
            : [virtual_address] "r" (virtual_address),
            : "memory"
        );
        return @as(u64, pt_entry.physical_page_base_address) << 12;
    }
}

pub fn virtual_to_physical(virtual_address: u64) u64 {
    g_state.lock.lock();
    defer g_state.lock.release();

    {
        const vaddr_2mb: amd64.VirtualAddress2MBPage = @bitCast(virtual_address);
        const pd_entry_2mb = &w64.get_pd_2mb(virtual_address).entries[vaddr_2mb.pd_offset];

        if (!pd_entry_2mb.present) {
            error_log.log_error(
                "No page directory entry for virtual address: {X}, pd: {X}, offset: {}, pd_entry_2mb: {}, PADDR: {X}",
                .{
                    virtual_address,
                    @intFromPtr(pd_entry_2mb),
                    vaddr_2mb.pd_offset,
                    pd_entry_2mb,
                    virtual_to_physical(@intFromPtr(pd_entry_2mb)),
                },
            );
            return 0;
        }

        //is it actually a 2MB page?
        if (pd_entry_2mb.must_be_one == 1) {
            const base_physical_address = @as(
                u64,
                pd_entry_2mb.physical_page_base_address,
            ) << 21;
            const effective_address = base_physical_address + (virtual_address &
                toolbox.mask_for_bit_range(0, 21, u64));
            return effective_address;
        }
    }

    //It is a 4KB page
    {
        const vaddr_4kb: amd64.VirtualAddress4KBPage = @bitCast(virtual_address);
        const pt_entry = w64.get_pt(virtual_address).entries[vaddr_4kb.pt_offset];
        if (!pt_entry.present) {
            error_log.log_error("No page table entry for virtual address: {X}", .{virtual_address});
            return 0;
        }
        const base_physical_address = @as(
            u64,
            pt_entry.physical_page_base_address,
        ) << 12;
        const effective_address = base_physical_address + (virtual_address &
            toolbox.mask_for_bit_range(0, 12, u64));
        return effective_address;
    }
}

pub fn generate_new_virtual_address(num_pages: usize, comptime page_size: usize) u64 {
    g_state.lock.lock();
    defer g_state.lock.release();

    //search from free list first
    const virtual_free_list = if (page_size == w64.MEMORY_PAGE_SIZE)
        &g_state.virtual_address_conventional_free_list
    else
        &g_state.virtual_address_mmio_free_list;
    var vaddr =
        search_for_free_address(num_pages, virtual_free_list);
    if (vaddr != 0) {
        return vaddr;
    }

    vaddr = g_state.next_free_virtual_address;
    if (!w64.is_kernel_address(vaddr)) {
        return 0;
    }
    if (toolbox.is_aligned_to(vaddr, page_size)) {
        const tmp = g_state.next_free_virtual_address +% (num_pages *% page_size);
        if (!w64.is_kernel_address(tmp) and tmp > 0) {
            return 0;
        }
        g_state.next_free_virtual_address = tmp;
        return vaddr;
    }

    g_state.next_free_virtual_address = vaddr +% page_size -% (vaddr % page_size);
    return generate_new_virtual_address(num_pages, page_size);
}

pub fn get_zig_std_allocator() std.mem.Allocator {
    return g_state.zig_std_allocator;
}

fn search_for_free_address(num_pages: usize, free_list: *FreeList) u64 {
    var it = free_list.iterator();
    while (it.next()) |entry| {
        if (entry.number_of_pages >= num_pages) {
            const address = entry.address;
            entry.number_of_pages -= num_pages;
            entry.address += entry.page_size;
            if (entry.number_of_pages == 0) {
                free_list.remove(entry);
            }
            return address;
        }
    }
    return 0;
}

fn calculate_next_free_conventional_physical_address(num_pages: usize) u64 {
    for (g_state.physical_address_conventional_pool) |*entry| {
        if (entry.number_of_pages >= num_pages) {
            const paddr = entry.physical_address;
            entry.physical_address += num_pages * w64.MEMORY_PAGE_SIZE;
            entry.number_of_pages -= num_pages;
            return paddr;
        }
    }
    return 0;
}
/// Attempt to allocate exactly `len` bytes aligned to `1 << ptr_align`.
///
/// `ret_addr` is optionally provided as the first return address of the
/// allocation call stack. If the value is `0` it means no return address
/// has been provided.
fn zig_std_alloc(ctx: *anyopaque, len: usize, ptr_align: u8, ret_addr: usize) ?[*]u8 {
    _ = ctx; // autofix
    _ = ret_addr; // autofix
    toolbox.assert(
        ptr_align <= w64.MEMORY_PAGE_SIZE,
        "Alignment is bigger than 2MB??? It is: {}",
        .{ptr_align},
    );
    const num_pages = toolbox.align_up(len, w64.MEMORY_PAGE_SIZE) / w64.MEMORY_PAGE_SIZE;
    return allocate_conventional(num_pages).ptr;
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
fn zig_std_resize(ctx: *anyopaque, buf: []u8, buf_align: u8, new_len: usize, ret_addr: usize) bool {
    _ = ctx; // autofix
    _ = buf_align; // autofix
    _ = ret_addr; // autofix
    const old_num_pages = toolbox.align_up(buf.len, w64.MEMORY_PAGE_SIZE) / w64.MEMORY_PAGE_SIZE;
    const new_num_pages = toolbox.align_up(new_len, w64.MEMORY_PAGE_SIZE) / w64.MEMORY_PAGE_SIZE;
    if (new_num_pages <= old_num_pages) {
        return true;
    }
    return false;
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
fn zig_std_free(ctx: *anyopaque, buf: []u8, buf_align: u8, ret_addr: usize) void {
    _ = ctx; // autofix
    _ = buf_align; // autofix
    _ = ret_addr; // autofix
    const vaddr = @intFromPtr(buf.ptr);
    const vaddr_aligned = toolbox.align_down(vaddr, w64.MEMORY_PAGE_SIZE);
    const new_len = buf.len + (vaddr - vaddr_aligned);

    const aligned_data =
        @as(
        [*]align(w64.MEMORY_PAGE_SIZE) u8,
        @ptrFromInt(vaddr_aligned),
    )[0..new_len];
    free_conventional(aligned_data);
}

///////Tests///////
test generate_new_virtual_address {
    const arena = toolbox.Arena.init(toolbox.mb(16));
    const physical_address_conventional_pool = [_]w64.ConventionalMemoryDescriptor{};
    init(
        arena,
        &physical_address_conventional_pool,
        0xFFFF_FFFF_9123_0000,
    );

    //MMIO virtual addresses
    var next_addr = generate_new_virtual_address(4, w64.MMIO_PAGE_SIZE);
    try std.testing.expectEqual(0xFFFF_FFFF_9123_0000, next_addr);
    try std.testing.expectEqual(0xFFFF_FFFF_9123_4000, g_state.next_free_virtual_address);
    next_addr = generate_new_virtual_address(4, w64.MMIO_PAGE_SIZE);
    try std.testing.expectEqual(0xFFFF_FFFF_9123_4000, next_addr);
    try std.testing.expectEqual(0xFFFF_FFFF_9123_8000, g_state.next_free_virtual_address);

    //Conventional memory virtual addresses
    next_addr = generate_new_virtual_address(4, w64.MEMORY_PAGE_SIZE);
    try std.testing.expectEqual(0xFFFF_FFFF_9140_0000, next_addr);
    try std.testing.expectEqual(0xFFFF_FFFF_91C0_0000, g_state.next_free_virtual_address);

    next_addr = generate_new_virtual_address(0xF_FFFF_FFFF, w64.MEMORY_PAGE_SIZE);
    try std.testing.expectEqual(0, next_addr);
    try std.testing.expectEqual(0xFFFF_FFFF_91C0_0000, g_state.next_free_virtual_address);
}

test search_for_free_address {
    const arena = toolbox.Arena.init(toolbox.mb(16));
    const physical_address_conventional_pool = [_]w64.ConventionalMemoryDescriptor{};
    init(
        arena,
        &physical_address_conventional_pool,
        0xFFFF_FFFF_9123_0000,
    );

    const free_list = &g_state.virtual_address_conventional_free_list;
    _ = free_list.append(.{
        .number_of_pages = 2,
        .address = 0xFFFF_FFFF_8000_0000,
        .page_size = w64.MEMORY_PAGE_SIZE,
    });

    _ = free_list.append(.{
        .number_of_pages = 4,
        .address = 0xFFFF_FFFF_81C0_0000,
        .page_size = w64.MEMORY_PAGE_SIZE,
    });

    var address =
        search_for_free_address(
        4,
        free_list,
    );
    try std.testing.expectEqual(0xFFFF_FFFF_81C0_0000, address);
    try std.testing.expectEqual(
        1,
        free_list.len,
    );

    address =
        search_for_free_address(
        4,
        free_list,
    );
    try std.testing.expectEqual(0, address);
    try std.testing.expectEqual(
        1,
        free_list.len,
    );
}

//TODO: cannot test this until we can dummy get_pml4t()
// test allocate_conventional {
//     const arena = toolbox.Arena.init(toolbox.mb(16));
//     var physical_address_conventional_pool = [_]w64.ConventionalMemoryDescriptor{
//         .{
//             .physical_address = 0x20_0000,
//             .number_of_pages = 2,
//         },
//     };
//     init(
//         arena,
//         &physical_address_conventional_pool,
//         0xFFFF_FFFF_9123_0000,
//     );
//     const vaddr = allocate_conventional(1);
//     try std.testing.expectEqual(0xFFFF_FFFF_9140_0000, vaddr);
// }

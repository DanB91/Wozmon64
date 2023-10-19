const toolbox = @import("toolbox");
const w64 = @import("wozmon64.zig");
const std = @import("std");
const amd64 = @import("amd64.zig");

const PageAllocatorBlock = struct {
    virtual_address: u64,
    number_of_pages: usize,
};
const PageAllocatorState = struct {
    allocated_blocks: toolbox.HashMap(u64, PageAllocatorBlock),
    free_blocks: toolbox.RandomRemovalLinkedList(PageAllocatorBlock),
    free_conventional_memory: []w64.ConventionalMemoryDescriptor,
    virtual_address_mappings: toolbox.RandomRemovalLinkedList(w64.VirtualMemoryMapping),
    next_free_virtual_address: u64,
    arena: *toolbox.Arena,
    lock: w64.ReentrantTicketLock,
};

var g_state: PageAllocatorState = undefined;

pub fn init(
    global_arena: *toolbox.Arena,
    next_free_virtual_address: u64,
    free_conventional_memory: []w64.ConventionalMemoryDescriptor,
    virtual_address_mappings: toolbox.RandomRemovalLinkedList(w64.VirtualMemoryMapping),
) void {
    g_state.arena = global_arena.create_arena_from_arena(toolbox.mb(1));
    const arena = g_state.arena;
    const allocated_blocks = toolbox.HashMap(u64, PageAllocatorBlock)
        .init(128, arena);
    const free_blocks = toolbox.RandomRemovalLinkedList(PageAllocatorBlock).init(arena);
    g_state = .{
        .arena = g_state.arena,
        .next_free_virtual_address = next_free_virtual_address,
        .allocated_blocks = allocated_blocks,
        .free_blocks = free_blocks,
        .free_conventional_memory = free_conventional_memory,
        .virtual_address_mappings = virtual_address_mappings,
        .lock = .{},
    };
}

pub fn pages_free() usize {
    g_state.lock.lock();
    defer g_state.lock.release();

    var ret: usize = 0;
    for (g_state.free_conventional_memory) |desc| {
        ret += desc.number_of_pages;
    }
    var it = g_state.free_blocks.iterator();
    while (it.next()) |block| {
        ret += block.number_of_pages;
    }
    return ret;
}

pub fn allocate(number_of_pages: usize) []u8 {
    g_state.lock.lock();
    defer g_state.lock.release();

    //first go through free list
    {
        var it = g_state.free_blocks.iterator();
        while (it.next()) |block_ptr| {
            const block = block_ptr.*;
            if (block.number_of_pages >= number_of_pages) {
                g_state.allocated_blocks.put(block.virtual_address, block);
                g_state.free_blocks.remove(block_ptr);
                return @as(
                    [*]u8,
                    @ptrFromInt(block.virtual_address),
                )[0 .. block.number_of_pages * w64.MEMORY_PAGE_SIZE];
            }
        }
    }

    //if nothing found, go to the free_conventional_memory structure
    const virtual_address = toolbox.align_up(g_state.next_free_virtual_address, w64.MEMORY_PAGE_SIZE);
    return allocate_at_address(virtual_address, number_of_pages);
}

pub fn allocate_at_address(virtual_address: u64, number_of_pages: usize) []u8 {
    g_state.lock.lock();
    defer g_state.lock.release();

    for (g_state.free_conventional_memory) |*desc| {
        if (desc.number_of_pages >= number_of_pages) {
            //  1) map virtual address
            const mapping_result = map_conventional_memory_physical_address(
                desc.physical_address,
                virtual_address,
                number_of_pages,
                g_state.arena,
            ) catch |e| toolbox.panic("Could not map virtual address {X} to {X}: {}", .{
                g_state.next_free_virtual_address,
                desc.physical_address,
                e,
            });
            g_state.next_free_virtual_address = mapping_result.next_free_virtual_address;
            //  2) update descriptor
            desc.number_of_pages -= number_of_pages;
            desc.physical_address += number_of_pages * w64.MEMORY_PAGE_SIZE;
            //  3) add to allocated block map
            g_state.allocated_blocks.put(virtual_address, .{
                .virtual_address = virtual_address,
                .number_of_pages = number_of_pages,
            });

            return @as(
                [*]u8,
                @ptrFromInt(virtual_address),
            )[0 .. number_of_pages * w64.MEMORY_PAGE_SIZE];
        }
    }
    toolbox.panic(
        "Out of page memory! Requested {} pages for virtual address: {X}",
        .{ number_of_pages, virtual_address },
    );
}

pub fn free(data: []u8) void {
    g_state.lock.lock();
    defer g_state.lock.release();

    const virtual_address = @intFromPtr(data.ptr);
    const block_opt = g_state.allocated_blocks.get(virtual_address);
    if (block_opt) |block| {
        _ = g_state.free_blocks.prepend(block);
    } else {
        toolbox.panic(
            "Trying to free address {X} which has not been allocated",
            .{virtual_address},
        );
    }
}
pub fn physical_to_virtual(
    physical_address: u64,
) !u64 {
    g_state.lock.lock();
    defer g_state.lock.release();

    var it = g_state.virtual_address_mappings.iterator();
    while (it.next()) |mapping| {
        if (physical_address >= mapping.physical_address and
            physical_address < mapping.physical_address + mapping.size)
        {
            const offset = physical_address - mapping.physical_address;
            return mapping.virtual_address + offset;
        }
    }
    return error.PhysicalAddressNotMapped;
}

pub fn virtual_to_physical(
    virtual_address: u64,
) !u64 {
    g_state.lock.lock();
    defer g_state.lock.release();
    //TODO: enable
    // {
    //     {
    //         const vaddr_2mb: amd64.VirtualAddress2MBPage = @bitCast(virtual_address);
    //         const pd_entry_2mb = get_pd_2mb(virtual_address).entries[vaddr_2mb.pd_offset];
    //         if (!pd_entry_2mb.present) {
    //             return error.VirtualAddressNotMapped;
    //         }

    //         //is it actually a 2MB page?
    //         if (pd_entry_2mb.must_be_one == 1) {
    //             const base_physical_address = @as(
    //                 u64,
    //                 pd_entry_2mb.physical_page_base_address,
    //             ) << 21;
    //             const effective_address = base_physical_address + (virtual_address &
    //                 toolbox.mask_for_bit_range(0, 21, u64));
    //             return effective_address;
    //         }
    //     }

    //     //It is a 4KB page
    //     {
    //         const vaddr_4kb: amd64.VirtualAddress4KBPage = @bitCast(virtual_address);
    //         const pt_entry = get_pt(virtual_address).entries[vaddr_4kb.pt_offset];
    //         if (!pt_entry.present) {
    //             return error.VirtualAddressNotMapped;
    //         }
    //         const base_physical_address = @as(
    //             u64,
    //             pt_entry.physical_page_base_address,
    //         ) << 12;
    //         const effective_address = base_physical_address + (virtual_address &
    //             toolbox.mask_for_bit_range(0, 12, u64));
    //         return effective_address;
    //     }
    // }
    //TODO use recursive mapping
    var it = g_state.virtual_address_mappings.iterator();
    while (it.next()) |mapping| {
        if (virtual_address >= mapping.virtual_address and
            virtual_address < mapping.virtual_address + mapping.size)
        {
            const offset = virtual_address - mapping.virtual_address;
            return mapping.physical_address + offset;
        }
    }
    return error.VirtualAddressNotMapped;
}

//returns mapped address
pub fn map_mmio_physical_address(
    starting_physical_address: u64,
    number_of_pages: usize,
    arena: *toolbox.Arena,
) u64 {
    g_state.lock.lock();
    defer g_state.lock.release();

    g_state.next_free_virtual_address = toolbox.align_up(g_state.next_free_virtual_address, w64.MMIO_PAGE_SIZE);

    const starting_virtual_address = g_state.next_free_virtual_address;
    for (0..number_of_pages) |i| {
        const virtual_address = starting_virtual_address + i * w64.MMIO_PAGE_SIZE;
        const physical_address = starting_physical_address + i * w64.MMIO_PAGE_SIZE;

        defer g_state.next_free_virtual_address += w64.MMIO_PAGE_SIZE;

        toolbox.assert(
            virtual_address > 0xFFFF_FF7F_FFFF_FFFF or virtual_address < 0xFFFF_FF80_0000_0000,
            "Mapping page table virtual address! physical address: {x}, virtual_address: {x}",
            .{ virtual_address, physical_address },
        );
        const vaddr_bits: amd64.VirtualAddress4KBPage = @bitCast(virtual_address);
        const pdp = b: {
            const pml4t = w64.get_pml4t();
            const entry = &pml4t.entries[vaddr_bits.pml4t_offset];
            if (!entry.present) {
                const pdp = arena.push_clear(amd64.PageDirectoryPointer);
                const page_physical_address = virtual_to_physical(
                    @intFromPtr(pdp),
                ) catch unreachable;
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
                ) catch unreachable;
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
                ) catch unreachable;
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
                toolbox.assert(
                    false,
                    "Trying map {x} to {x}, which is already mapped to {x}. Starting virtual address: {x}",
                    .{
                        virtual_address,
                        physical_address,
                        entry.physical_page_base_address,
                        starting_virtual_address,
                    },
                );
            }
        }
    }
    _ = g_state.virtual_address_mappings.append(.{
        .physical_address = starting_physical_address,
        .virtual_address = starting_virtual_address,
        .size = number_of_pages * w64.MMIO_PAGE_SIZE,
        .memory_type = .MMIOMemory,
    });
    return starting_virtual_address;
}
pub const MapMemoryResult = struct {
    virtual_address: u64,
    next_free_virtual_address: u64,
};
pub fn map_conventional_memory_physical_address(
    starting_physical_address: u64,
    starting_virtual_address: u64,
    number_of_pages: usize,
    arena: *toolbox.Arena,
) !MapMemoryResult {
    g_state.lock.lock();
    defer g_state.lock.release();

    if (!toolbox.is_aligned_to(starting_virtual_address, w64.MEMORY_PAGE_SIZE)) {
        return error.VirtualAddressNotPageAligned;
    }
    if (!toolbox.is_aligned_to(starting_physical_address, w64.MEMORY_PAGE_SIZE)) {
        return error.PhysicalAddressNotPageAligned;
    }

    var virtual_address = starting_virtual_address;
    var physical_address = starting_physical_address;
    for (0..number_of_pages) |_| {
        toolbox.assert(
            virtual_address > 0xFFFF_FF7F_FFFF_FFFF or virtual_address < 0xFFFF_FF80_0000_0000,
            "Mapping page table virtual address! physical address: {x}, virtual_address: {x}",
            .{ virtual_address, physical_address },
        );
        // if (comptime toolbox.IS_DEBUG) {
        //     var it = mappings.iterator();
        //     while (it.next()) |mapping| {
        //         toolbox.assert(
        //             virtual_address + MEMORY_PAGE_SIZE <= mapping.virtual_address or virtual_address >= mapping.virtual_address + mapping.size,
        //             "Mapping virtual address {X}, when it is already mapped to {X}!",
        //             .{ virtual_address, mapping.physical_address },
        //         );
        //     }
        // }
        const vaddr_bits: amd64.VirtualAddress2MBPage = @bitCast(virtual_address);
        const pdp = b: {
            const pml4t = w64.get_pml4t();
            const entry = &pml4t.entries[vaddr_bits.pml4t_offset];
            if (!entry.present) {
                const pdp = arena.push_clear(amd64.PageDirectoryPointer);
                const page_physical_address = virtual_to_physical(
                    @intFromPtr(pdp),
                ) catch unreachable;
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
                ) catch unreachable;
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
                if (entry.must_be_one == 1) {
                    toolbox.panic(
                        "Expected 2MB PD, but was 4KB! Attempted virtual address to map: {X}",
                        .{virtual_address},
                    );
                }
                return error.VirtualAddressAlreadyMapped;
            }
        }
        virtual_address += w64.MEMORY_PAGE_SIZE;
        physical_address += w64.MEMORY_PAGE_SIZE;
    }
    _ = g_state.virtual_address_mappings.append(.{
        .physical_address = starting_physical_address,
        .virtual_address = starting_virtual_address,
        .size = number_of_pages * w64.MEMORY_PAGE_SIZE,
        .memory_type = .ConventionalMemory,
    });
    return .{
        .virtual_address = starting_virtual_address,
        .next_free_virtual_address = virtual_address,
    };
}

const toolbox = @import("toolbox");
const w64 = @import("wozmon64.zig");

const PageAllocatorBlock = struct {
    virtual_address: u64,
    number_of_pages: usize,
};
const PageAllocatorState = struct {
    allocated_blocks: toolbox.HashMap(u64, PageAllocatorBlock),
    free_blocks: toolbox.RandomRemovalLinkedList(PageAllocatorBlock),
    free_conventional_memory: []w64.ConventionalMemoryDescriptor,
    virtual_address_mappings: *toolbox.RandomRemovalLinkedList(w64.VirtualMemoryMapping),
    next_free_virtual_address: *u64,
    arena: *toolbox.Arena,
};

var g_state: PageAllocatorState = undefined;

pub fn init(
    global_arena: *toolbox.Arena,
    next_free_virtual_address: *u64,
    free_conventional_memory: []w64.ConventionalMemoryDescriptor,
    virtual_address_mappings: *toolbox.RandomRemovalLinkedList(w64.VirtualMemoryMapping),
) void {
    g_state.arena = global_arena.create_arena_from_arena(toolbox.kb(128));
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
    };
}

pub fn pages_free() usize {
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
    {
        for (g_state.free_conventional_memory) |*desc| {
            if (desc.number_of_pages >= number_of_pages) {
                //TODO:
                //  1) map next free virtual address
                const virtual_address = w64.map_conventional_memory_physical_address(
                    desc.physical_address,
                    g_state.next_free_virtual_address,
                    number_of_pages,
                    g_state.arena,
                    g_state.virtual_address_mappings,
                );
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
    }
    toolbox.panic("Out of page memory!", .{});
}

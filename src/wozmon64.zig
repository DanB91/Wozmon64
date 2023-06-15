//Copyright Daniel Bokser 2023
//See LICENSE file for permissible source code usage

const toolbox = @import("toolbox");
const amd64 = @import("amd64.zig");
pub usingnamespace @import("bitmaps.zig");

pub const MEMORY_PAGE_SIZE = toolbox.mb(2);
pub const MMIO_PAGE_SIZE = toolbox.kb(4);

//TODO change to 1920
pub const TARGET_RESOLUTION = .{
    .width = 1280,
    .height = 720,
    // .width = 3840,
    // .height = 2160,
};

pub const FRAME_BUFFER_VIRTUAL_ADDRESS = 0x20_0000;

pub const Pixel = packed union {
    colors: packed struct(u32) {
        b: u8,
        g: u8,
        r: u8,
        reserved: u8 = 0,
    },
    data: u32,
};

pub const Screen = struct {
    frame_buffer: []volatile Pixel,
    back_buffer: []Pixel,
    width: usize,
    height: usize,
    stride: usize,
};

pub const KernelStartContext = struct {
    screen: Screen,
    rsdp: *amd64.ACPI2RSDP,
    global_arena: toolbox.Arena,
    mapped_memory: []VirtualMemoryMapping,
    free_conventional_memory: []ConventionalMemoryDescriptor,
    bootstrap_address_to_unmap: u64,
};

pub const ConventionalMemoryDescriptor = struct {
    physical_address: u64,
    number_of_pages: usize,

    const PAGE_SIZE = MEMORY_PAGE_SIZE;
};
pub const MemoryType = enum {
    ConventionalMemory,
    MMIOMemory,
    FrameBufferMemory,
};
pub const VirtualMemoryMapping = struct {
    physical_address: u64,
    virtual_address: u64,
    size: usize, //in bytes
    memory_type: MemoryType,
};
pub fn physical_to_virtual(physical_address: u64, mappings: []VirtualMemoryMapping) !u64 {
    for (mappings) |mapping| {
        if (physical_address >= mapping.physical_address and
            physical_address < mapping.physical_address + mapping.size)
        {
            const offset = physical_address - mapping.physical_address;
            return mapping.virtual_address + offset;
        }
    }
    return error.PhysicalAddressNotMapped;
}

comptime {
    toolbox.static_assert(@sizeOf(Pixel) == 4, "Incorrect size for Pixel");
}

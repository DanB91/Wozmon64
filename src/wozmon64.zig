//Copyright Daniel Bokser 2023
//See LICENSE file for permissible source code usage

const toolbox = @import("toolbox");
const amd64 = @import("amd64.zig");
const kernel = @import("kernel.zig");
const bitmaps = @import("bitmaps.zig");

pub const MEMORY_PAGE_SIZE = toolbox.mb(2);
pub const MMIO_PAGE_SIZE = toolbox.kb(4);

pub const KERNEL_GLOBAL_ARENA_SIZE = toolbox.mb(128);
pub const KERNEL_FRAME_ARENA_SIZE = toolbox.mb(4);
pub const KERNEL_SCRATCH_ARENA_SIZE = toolbox.mb(4);

pub const FRAME_BUFFER_VIRTUAL_ADDRESS = 0x20_0000;

pub const DisplayConfiguration = struct {};

pub const Pixel = packed union {
    colors: packed struct(u32) {
        b: u8,
        g: u8,
        r: u8,
        reserved: u8 = 0,
    },
    data: u32,
};

pub const SUPPORTED_RESOLUTIONS = [_]struct { width: u32, height: u32 }{
    .{ .width = 3840, .height = 2160 },
    .{ .width = 1920, .height = 1080 },
    .{ .width = 1280, .height = 720 },
};

pub const Screen = struct {
    frame_buffer: []volatile Pixel,
    back_buffer: []Pixel,
    font: bitmaps.Font,

    width: usize,
    height: usize,
    stride: usize,

    width_in_characters: usize,
    height_in_characters: usize,

    pub fn init(
        width: usize,
        height: usize,
        stride: usize,
        frame_buffer: []volatile Pixel,
        arena: *toolbox.Arena,
    ) Screen {
        const scale: usize = b: {
            if (width == 3840 and height == 2160) {
                break :b 6;
            } else if (width == 1920 and height == 1080) {
                break :b 4;
            } else if (width == 1280 and height == 720) {
                break :b 2; //4;
            } else {
                toolbox.panic("Unsupported resolution: {}x{}", .{ width, height });
            }
        };
        const back_buffer = arena.push_slice_clear(Pixel, frame_buffer.len);
        const font = bitmaps.Font.init(scale, arena);
        return .{
            .frame_buffer = frame_buffer,
            .back_buffer = back_buffer,
            .font = font,

            .width = width,
            .height = height,
            .stride = stride,

            .width_in_characters = @divTrunc(width, font.kerning),
            .height_in_characters = @divTrunc(height, font.height),
        };
    }
};

pub const BootloaderProcessorContext = struct {
    is_booted: bool,
    pml4_table_address: u64,
    application_processor_kernel_entry_data: ?struct {
        entry: *const fn (
            context: *ApplicationProcessorKernelStartContext,
            processor_id: u64,
        ) noreturn,
        cr3: u64, //page table address
        rsp: u64, //initial stack pointer
        start_context_data: *anyopaque,
    },
};

pub const ApplicationProcessorKernelStartContext = struct {
    processor_id: u64,
};

pub const KernelStartContext = struct {
    screen: Screen,
    rsdp: *amd64.ACPI2RSDP,
    global_arena: toolbox.Arena,
    mapped_memory: []VirtualMemoryMapping,
    free_conventional_memory: []ConventionalMemoryDescriptor,
    application_processor_contexts: []*BootloaderProcessorContext,
    tsc_mhz: u64,
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
    ToBeUnmapped,
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

pub fn virtual_to_physical(virtual_address: u64, mappings: []VirtualMemoryMapping) !u64 {
    //TODO use recursive mapping
    for (mappings) |mapping| {
        if (virtual_address >= mapping.virtual_address and
            virtual_address < mapping.virtual_address + mapping.size)
        {
            const offset = virtual_address - mapping.virtual_address;
            return mapping.virtual_address + offset;
        }
    }
    return error.VirtualAddressNotMapped;
}

pub const Time = struct {
    ticks: i64,

    var ticks_to_microseconds: i64 = 0;
    pub fn init(tsc_mhz: u64) void {
        ticks_to_microseconds = @intCast(tsc_mhz);
    }

    pub inline fn sub(self: Time, other: Time) Time {
        return .{ .ticks = self.ticks - other.ticks };
    }

    pub inline fn nanoseconds(self: Time) i64 {
        return self.microseconds() * 1000;
    }
    pub inline fn microseconds(self: Time) i64 {
        return @divTrunc(@as(i64, @intCast(self.ticks)), ticks_to_microseconds);
    }
    pub inline fn milliseconds(self: Time) i64 {
        return @divTrunc(self.microseconds(), 1000);
    }
    pub inline fn seconds(self: Time) i64 {
        return @divTrunc(self.microseconds(), 1_000_000);
    }
    pub inline fn minutes(self: Time) i64 {
        return @divTrunc(self.microseconds(), 1_000_000 / 60);
    }
    pub inline fn hours(self: Time) i64 {
        return @divTrunc(self.microseconds(), 1_000_000 / 60 / 60);
    }
    pub inline fn days(self: Time) i64 {
        return @divTrunc(self.microseconds(), 1_000_000 / 60 / 60 / 24);
    }
};

pub fn now() Time {
    return .{ .ticks = @intCast(amd64.rdtsc()) };
}

comptime {
    toolbox.static_assert(@sizeOf(Pixel) == 4, "Incorrect size for Pixel");
}

//userspace functions
pub fn echo(bytes: [*c]u8, len: usize) void {
    const str = toolbox.str8(bytes[0..len]);
    kernel.echo_str8("{}", .{str});
}

//Copyright Daniel Bokser 2023
//See LICENSE file for permissible source code usage

const std = @import("std");
const toolbox = @import("toolbox");
const amd64 = @import("amd64.zig");
const kernel = @import("kernel.zig");
const bitmaps = @import("bitmaps.zig");

pub const MEMORY_PAGE_SIZE = toolbox.mb(2);
pub const MMIO_PAGE_SIZE = toolbox.kb(4);
pub const PAGE_TABLE_PAGE_SIZE = toolbox.kb(4);
pub const PHYSICAL_ADDRESS_ALIGNMENT = toolbox.kb(4);

pub const KERNEL_GLOBAL_ARENA_SIZE = toolbox.mb(512);
pub const KERNEL_FRAME_ARENA_SIZE = toolbox.mb(4);
pub const KERNEL_SCRATCH_ARENA_SIZE = toolbox.mb(4);

pub const FRAME_BUFFER_VIRTUAL_ADDRESS = 0x20_0000;

//Frame buffer data
pub const SCREEN_PIXEL_WIDTH_ADDRESS = 0x220_0030;
pub const SCREEN_PIXEL_HEIGHT_ADDRESS = 0x220_0038;
pub const FRAME_BUFFER_SIZE_ADDRESS = 0x220_0040;

pub const PAGE_TABLE_RECURSIVE_OFFSET = 510;

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
    //.{ .width = 3840, .height = 2160 },
    //.{ .width = 1920, .height = 1080 },
    .{ .width = 1280, .height = 720 },
};

pub const Screen = struct {
    frame_buffer: []volatile Pixel,
    back_buffer: []Pixel,
    font: bitmaps.Font,

    width: usize,
    height: usize,
    stride: usize,

    width_in_runes: usize,
    height_in_runes: usize,

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

            .width_in_runes = @divTrunc(width, font.kerning),
            .height_in_runes = @divTrunc(height, font.height),
        };
    }
};

pub const BootloaderProcessorContext = struct {
    is_booted: bool,
    pml4_table_address: u64,
    processor_id: u64,
    application_processor_kernel_entry_data: ?struct {
        entry: *const fn (
            context: *ApplicationProcessorKernelStartContext,
        ) noreturn,
        cr3: u64, //page table address
        rsp: u64, //initial stack pointer
        start_context_data: *anyopaque,
    },
};

pub const ApplicationProcessorKernelStartContext = struct {};

pub const KernelStartContext = struct {
    screen: Screen,
    root_xsdt: *const amd64.XSDT,
    global_arena: *toolbox.Arena,
    mapped_memory: []VirtualMemoryMapping,
    free_conventional_memory: []ConventionalMemoryDescriptor,
    next_free_virtual_address: u64,
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
pub fn physical_to_virtual(
    physical_address: u64,
    mappings: toolbox.RandomRemovalLinkedList(VirtualMemoryMapping),
) !u64 {
    var it = mappings.iterator();
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
    mappings: *const toolbox.RandomRemovalLinkedList(VirtualMemoryMapping),
) !u64 {
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
    var it = mappings.iterator();
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
pub const MapMemoryResult = struct {
    virtual_address: u64,
    next_free_virtual_address: u64,
};
pub fn map_conventional_memory_physical_address(
    starting_physical_address: u64,
    //TODO: i think we should get rid of this pointer and return the new virtual address instead
    starting_virtual_address: u64,
    number_of_pages: usize,
    arena: *toolbox.Arena,
    mappings: *toolbox.RandomRemovalLinkedList(VirtualMemoryMapping),
) !MapMemoryResult {
    if (!toolbox.is_aligned_to(starting_virtual_address, MEMORY_PAGE_SIZE)) {
        return error.VirtualAddressNotPageAligned;
    }
    if (!toolbox.is_aligned_to(starting_physical_address, MEMORY_PAGE_SIZE)) {
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
            const pml4t = get_pml4t();
            const entry = &pml4t.entries[vaddr_bits.pml4t_offset];
            if (!entry.present) {
                const pdp = arena.push_clear(amd64.PageDirectoryPointer);
                const page_physical_address = virtual_to_physical(
                    @intFromPtr(pdp),
                    mappings,
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
                break :b get_pdp(virtual_address);
            }
        };
        const pd = b: {
            const entry = &pdp.entries[vaddr_bits.pdp_offset];
            if (!entry.present) {
                const pd = arena.push_clear(amd64.PageDirectory2MB);
                const page_physical_address = virtual_to_physical(
                    @intFromPtr(pd),
                    mappings,
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
                break :b get_pd_2mb(virtual_address);
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
        virtual_address += MEMORY_PAGE_SIZE;
        physical_address += MEMORY_PAGE_SIZE;
    }
    _ = mappings.append(.{
        .physical_address = starting_physical_address,
        .virtual_address = starting_virtual_address,
        .size = number_of_pages * MEMORY_PAGE_SIZE,
        .memory_type = .ConventionalMemory,
    });
    return .{
        .virtual_address = starting_virtual_address,
        .next_free_virtual_address = virtual_address,
    };
}

fn print_serial(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const to_print = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch unreachable;

    for (to_print) |byte| {
        asm volatile (
            \\mov $0x3F8, %%dx
            \\mov %[char], %%al
            \\outb %%al, %%dx
            :
            : [char] "r" (byte),
            : "rax", "rdx"
        );
    }
}
//returns mapped address
pub fn map_mmio_physical_address(
    starting_physical_address: u64,
    starting_virtual_address_ptr: *u64, //increments to next free address
    number_of_pages: usize,
    arena: *toolbox.Arena,
    mappings: *toolbox.RandomRemovalLinkedList(VirtualMemoryMapping),
) u64 {
    starting_virtual_address_ptr.* = toolbox.align_up(starting_virtual_address_ptr.*, MMIO_PAGE_SIZE);

    const starting_virtual_address = starting_virtual_address_ptr.*;
    for (0..number_of_pages) |i| {
        const virtual_address = starting_virtual_address + i * MMIO_PAGE_SIZE;
        const physical_address = starting_physical_address + i * MMIO_PAGE_SIZE;

        defer starting_virtual_address_ptr.* += MMIO_PAGE_SIZE;

        toolbox.assert(
            virtual_address > 0xFFFF_FF7F_FFFF_FFFF or virtual_address < 0xFFFF_FF80_0000_0000,
            "Mapping page table virtual address! physical address: {x}, virtual_address: {x}",
            .{ virtual_address, physical_address },
        );
        const vaddr_bits: amd64.VirtualAddress4KBPage = @bitCast(virtual_address);
        const pdp = b: {
            const pml4t = get_pml4t();
            const entry = &pml4t.entries[vaddr_bits.pml4t_offset];
            if (!entry.present) {
                const pdp = arena.push_clear(amd64.PageDirectoryPointer);
                const page_physical_address = virtual_to_physical(
                    @intFromPtr(pdp),
                    mappings,
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
                break :b get_pdp(virtual_address);
            }
        };
        const pd = b: {
            const entry = &pdp.entries[vaddr_bits.pdp_offset];
            if (!entry.present) {
                const pd = arena.push_clear(amd64.PageDirectory4KB);
                const page_physical_address = virtual_to_physical(
                    @intFromPtr(pd),
                    mappings,
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
                break :b get_pd_4kb(virtual_address);
            }
        };
        const pt = b: {
            const entry = &pd.entries[vaddr_bits.pd_offset];
            if (!entry.present) {
                const pt = arena.push_clear(amd64.PageTable);
                const page_physical_address = virtual_to_physical(
                    @intFromPtr(pt),
                    mappings,
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
                break :b get_pt(virtual_address);
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
    _ = mappings.append(.{
        .physical_address = starting_physical_address,
        .virtual_address = starting_virtual_address,
        .size = number_of_pages * MMIO_PAGE_SIZE,
        .memory_type = .MMIOMemory,
    });
    return starting_virtual_address;
}

pub fn get_pml4t() *amd64.PageMappingLevel4Table {
    const address = amd64.VirtualAddress4KBPage{
        .signed_bits = 0xFFFF,
        .pml4t_offset = PAGE_TABLE_RECURSIVE_OFFSET,
        .pdp_offset = PAGE_TABLE_RECURSIVE_OFFSET,
        .pd_offset = PAGE_TABLE_RECURSIVE_OFFSET,
        .pt_offset = PAGE_TABLE_RECURSIVE_OFFSET,
        .page_offset = 0,
    };
    return address.to(*amd64.PageMappingLevel4Table);
}

pub fn get_pdp(virtual_address: u64) *amd64.PageDirectoryPointer {
    const vaddr_bits: amd64.VirtualAddress4KBPage = @bitCast(virtual_address);
    const pdp_address = amd64.VirtualAddress4KBPage{
        .signed_bits = 0xFFFF,
        .pml4t_offset = PAGE_TABLE_RECURSIVE_OFFSET,
        .pdp_offset = PAGE_TABLE_RECURSIVE_OFFSET,
        .pd_offset = PAGE_TABLE_RECURSIVE_OFFSET,
        .pt_offset = vaddr_bits.pml4t_offset,
        .page_offset = 0,
    };
    return pdp_address.to(*amd64.PageDirectoryPointer);
}
pub fn get_pd_4kb(virtual_address: u64) *amd64.PageDirectory4KB {
    const vaddr_bits: amd64.VirtualAddress4KBPage = @bitCast(virtual_address);
    const pd_address = amd64.VirtualAddress4KBPage{
        .signed_bits = 0xFFFF,
        .pml4t_offset = PAGE_TABLE_RECURSIVE_OFFSET,
        .pdp_offset = PAGE_TABLE_RECURSIVE_OFFSET,
        .pd_offset = vaddr_bits.pml4t_offset,
        .pt_offset = vaddr_bits.pdp_offset,
        .page_offset = 0,
    };
    return pd_address.to(*amd64.PageDirectory4KB);
}
pub fn get_pd_2mb(virtual_address: u64) *amd64.PageDirectory2MB {
    const vaddr_bits: amd64.VirtualAddress4KBPage = @bitCast(virtual_address);
    const pd_address = amd64.VirtualAddress4KBPage{
        .signed_bits = 0xFFFF,
        .pml4t_offset = PAGE_TABLE_RECURSIVE_OFFSET,
        .pdp_offset = PAGE_TABLE_RECURSIVE_OFFSET,
        .pd_offset = vaddr_bits.pml4t_offset,
        .pt_offset = vaddr_bits.pdp_offset,
        .page_offset = 0,
    };
    return pd_address.to(*amd64.PageDirectory2MB);
}
pub fn get_pt(virtual_address: u64) *amd64.PageTable {
    const vaddr_bits: amd64.VirtualAddress4KBPage = @bitCast(virtual_address);
    const pt_address = amd64.VirtualAddress4KBPage{
        .signed_bits = 0xFFFF,
        .pml4t_offset = PAGE_TABLE_RECURSIVE_OFFSET,
        .pdp_offset = vaddr_bits.pml4t_offset,
        .pd_offset = vaddr_bits.pdp_offset,
        .pt_offset = vaddr_bits.pd_offset,
        .page_offset = 0,
    };
    return pt_address.to(*amd64.PageTable);
}

pub fn pdp_from_virtual_address(virtual_address: u64) *amd64.PageDirectoryPointer {
    const pdp_index = (virtual_address >> (12 + 9 + 9)) & 0xFF8;
    return @ptrFromInt(0xFFFF_FF7F_BF80_0000 | (pdp_index << (12 + 9 + 9)));
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

pub fn delay_milliseconds(n: i64) void {
    const start = now();
    while (now().sub(start).milliseconds() < n) {
        std.atomic.spinLoopHint();
    }
}

comptime {
    toolbox.static_assert(@sizeOf(Pixel) == 4, "Incorrect size for Pixel");
}

//userspace functions
pub fn echo(bytes: [*c]u8, len: usize) void {
    const str = toolbox.str8(bytes[0..len]);
    kernel.echo_str8("{}", .{str});
}

pub const InputState = struct {
    modifier_key_pressed_events: toolbox.RingQueue(ScanCode),
    modifier_key_released_events: toolbox.RingQueue(ScanCode),
    key_pressed_events: toolbox.RingQueue(ScanCode),
    key_released_events: toolbox.RingQueue(ScanCode),

    pub fn init(arena: *toolbox.Arena) InputState {
        const keys_pressed = toolbox.RingQueue(ScanCode).init(64, arena);
        const keys_released = toolbox.RingQueue(ScanCode).init(64, arena);
        const modifier_keys_pressed = toolbox.RingQueue(ScanCode).init(16, arena);
        const modifier_keys_released = toolbox.RingQueue(ScanCode).init(16, arena);

        return .{
            .key_pressed_events = keys_pressed,
            .key_released_events = keys_released,
            .modifier_key_pressed_events = modifier_keys_pressed,
            .modifier_key_released_events = modifier_keys_released,
        };
    }
};

pub const ScanCode = enum {
    Unknown,
    A,
    B,
    C,
    D,
    E,
    F,
    G,
    H,
    I,
    J,
    K,
    L,
    M,
    N,
    O,
    P,
    Q,
    R,
    S,
    T,
    U,
    V,
    W,
    X,
    Y,
    Z,

    Zero,
    One,
    Two,
    Three,
    Four,
    Five,
    Six,
    Seven,
    Eight,
    Nine,

    CapsLock,
    ScrollLock,
    NumLock,
    LeftShift,
    LeftCtrl,
    LeftAlt,
    LeftFlag,
    RightShift,
    RightCtrl,
    RightAlt,
    RightFlag,
    Pause,
    ContextMenu,

    Backspace,
    Escape,
    Insert,
    Home,
    PageUp,
    Delete,
    End,
    PageDown,
    UpArrow,
    LeftArrow,
    DownArrow,
    RightArrow,

    Space,
    Tab,
    Enter,

    Slash,
    Backslash,
    LeftBracket,
    RightBracket,
    Equals,
    Backtick,
    Hyphen,
    Semicolon,
    Quote,
    Comma,
    Period,

    NumDivide,
    NumMultiply,
    NumSubtract,
    NumAdd,
    NumEnter,
    NumPoint,
    Num0,
    Num1,
    Num2,
    Num3,
    Num4,
    Num5,
    Num6,
    Num7,
    Num8,
    Num9,

    PrintScreen,
    PrintScreen1,
    PrintScreen2,

    F1,
    F2,
    F3,
    F4,
    F5,
    F6,
    F7,
    F8,
    F9,
    F10,
    F11,
    F12,
};
pub fn scancode_to_ascii_shifted(scancode: ScanCode) u8 {
    return switch (scancode) {
        .Zero => ')',
        .One => '!',
        .Two => '@',
        .Three => '#',
        .Four => '$',
        .Five => '%',
        .Six => '^',
        .Seven => '&',
        .Eight => '*',
        .Nine => '(',

        .Slash => '?',
        .Backslash => '|',
        .LeftBracket => '{',
        .RightBracket => '}',
        .Equals => '+',
        .Backtick => '~',
        .Hyphen => '_',
        .Semicolon => ':',
        .Quote => '"',
        .Comma => '<',
        .Period => '>',

        else => scancode_to_ascii(scancode),
    };
}

pub fn scancode_to_ascii(scancode: ScanCode) u8 {
    return switch (scancode) {
        .A => 'A',
        .B => 'B',
        .C => 'C',
        .D => 'D',
        .E => 'E',
        .F => 'F',
        .G => 'G',
        .H => 'H',
        .I => 'I',
        .J => 'J',
        .K => 'K',
        .L => 'L',
        .M => 'M',
        .N => 'N',
        .O => 'O',
        .P => 'P',
        .Q => 'Q',
        .R => 'R',
        .S => 'S',
        .T => 'T',
        .U => 'U',
        .V => 'V',
        .W => 'W',
        .X => 'X',
        .Y => 'Y',
        .Z => 'Z',

        .Zero => '0',
        .One => '1',
        .Two => '2',
        .Three => '3',
        .Four => '4',
        .Five => '5',
        .Six => '6',
        .Seven => '7',
        .Eight => '8',
        .Nine => '9',

        .Space => ' ',
        .Enter => '\n',

        .Slash => '/',
        .Backslash => '\\',
        .LeftBracket => '[',
        .RightBracket => ']',
        .Equals => '=',
        .Backtick => '`',
        .Hyphen => '-',
        .Semicolon => ';',
        .Quote => '\'',
        .Comma => ',',
        .Period => '.',

        else => '?',
    };
}

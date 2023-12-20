//Copyright Daniel Bokser 2023
//See LICENSE file for permissible source code usage

pub usingnamespace @import("wozmon64_user.zig");

const w64_user = @import("wozmon64_user.zig");
const std = @import("std");
const toolbox = @import("toolbox");
const amd64 = @import("amd64.zig");
const bitmaps = @import("bitmaps.zig");

pub const MMIO_PAGE_SIZE = toolbox.kb(4);
pub const PAGE_TABLE_PAGE_SIZE = toolbox.kb(4);
pub const PHYSICAL_ADDRESS_ALIGNMENT = toolbox.kb(4);

pub const KERNEL_GLOBAL_ARENA_SIZE = toolbox.mb(512);
pub const KERNEL_FRAME_ARENA_SIZE = toolbox.mb(4);
pub const KERNEL_SCRATCH_ARENA_SIZE = toolbox.mb(4);

pub const PAGE_TABLE_RECURSIVE_OFFSET = 510;

pub const SUPPORTED_RESOLUTIONS = [_]struct {
    width: u32,
    height: u32,
}{
    // .{ .width = 3840, .height = 2160 },
    // .{ .width = 1920, .height = 1080 },
    .{ .width = 1280, .height = 720 },
    .{ .width = 800, .height = 1280 },
};

pub const Screen = struct {
    frame_buffer: []volatile w64_user.Pixel,
    back_buffer: []w64_user.Pixel,
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
        frame_buffer: []volatile w64_user.Pixel,
        arena: *toolbox.Arena,
    ) Screen {
        const scale: usize = b: {
            if (width == 3840 and height == 2160) {
                break :b 6;
            } else if (width == 1920 and height == 1080) {
                break :b 4;
            } else if (width == 1280 and height == 720) {
                break :b 2; //4;
            } else if (width == 800 and height == 1280) {
                break :b 2; //4;
            } else {
                //fatal error.  draw red screen
                for (frame_buffer) |*pixel| {
                    pixel.colors = .{ .r = 255, .g = 0, .b = 0 };
                }
                toolbox.hang();
            }
        };
        const back_buffer = arena.push_slice_clear(w64_user.Pixel, frame_buffer.len);
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
    application_processor_kernel_entry_data: Atomic(?struct {
        entry: *const fn (
            context: *ApplicationProcessorKernelContext,
        ) callconv(.C) noreturn,
        cr3: u64, //page table address
        rsp: u64, //initial stack pointer
        start_context_data: *ApplicationProcessorKernelContext,
    }),
};

pub const ApplicationProcessorKernelContext = struct {
    processor_id: u64,
    rsp: u64, //initial stack pointer
    cr3: u64, //page table address
    fsbase: u64, //fs base address
    gsbase: u64, //gs base address
    job: Atomic(?struct {
        entry: *const fn (user_data: ?*anyopaque) callconv(.C) void,
        user_data: ?*anyopaque,
    }),
};

pub const KernelStartContext = struct {
    screen: Screen,
    root_xsdt: *const amd64.XSDT,
    global_arena: *toolbox.Arena,
    mapped_memory: []VirtualMemoryMapping,
    free_conventional_memory: []ConventionalMemoryDescriptor,
    next_free_virtual_address: u64,
    bootloader_processor_contexts: []*BootloaderProcessorContext,
    tsc_mhz: u64,
    kernel_elf_bytes: []const u8,
};

pub const ConventionalMemoryDescriptor = struct {
    physical_address: u64,
    number_of_pages: usize,

    const PAGE_SIZE = w64_user.MEMORY_PAGE_SIZE;
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

pub fn get_core_id() u64 {
    return amd64.rdmsr(amd64.IA32_TSC_AUX_MSR);
}

pub fn Atomic(comptime T: type) type {
    return struct {
        value: T,
        lock: ReentrantTicketLock = .{},

        const Self = @This();

        pub const get = switch (@sizeOf(T)) {
            1, 2, 4, 8 => get_register,
            else => get_generic,
        };
        pub const set = switch (@sizeOf(T)) {
            1, 2, 4, 8 => set_register,
            else => set_generic,
        };

        fn get_generic(self: *Self) T {
            self.lock.lock();
            const value = self.value;
            self.lock.release();
            return value;
        }

        fn set_generic(self: *Self, value: T) void {
            self.lock.lock();
            self.value = value;
            self.lock.release();
        }

        inline fn get_register(self: *Self) T {
            const RegisterType = get_register_type();
            const reg_value: RegisterType = @bitCast(self.value);
            return @bitCast(@atomicLoad(RegisterType, &reg_value, .SeqCst));
        }

        inline fn set_register(self: *Self, value: T) void {
            const RegisterType = get_register_type();
            const reg_value: RegisterType = @bitCast(value);
            @atomicStore(RegisterType, &self.value, reg_value, .SeqCst);
        }

        fn get_register_type() type {
            return switch (@sizeOf(T)) {
                1 => u8,
                2 => u16,
                4 => u32,
                8 => u64,
                else => @compileError("Incorrect usage of get_register_type!"),
            };
        }
    };
}

pub const ReentrantTicketLock = struct {
    serving: u64 = 0,
    taken: u64 = 0,

    recursion_level: u64 = 0,
    core_id: i64 = -1,

    pub fn lock(self: *ReentrantTicketLock) void {
        const core_id = @atomicLoad(i64, &self.core_id, .SeqCst);
        if (core_id == get_core_id()) {
            self.recursion_level += 1;
            return;
        }
        const ticket = @atomicRmw(u64, &self.taken, .Add, 1, .SeqCst);
        while (true) {
            if (@cmpxchgWeak(
                u64,
                &self.serving,
                ticket,
                ticket,
                .AcqRel,
                .Acquire,
            ) == null) {
                @atomicStore(i64, &self.core_id, @intCast(get_core_id()), .SeqCst);
                self.recursion_level = 1;
                return;
            } else {
                std.atomic.spinLoopHint();
            }
        }
    }

    pub fn release(self: *ReentrantTicketLock) void {
        self.recursion_level -= 1;
        if (self.recursion_level == 0) {
            @atomicStore(i64, &self.core_id, @intCast(-1), .SeqCst);
            _ = @atomicRmw(u64, &self.serving, .Add, 1, .SeqCst);
        }
    }
};

comptime {
    toolbox.static_assert(@sizeOf(w64_user.Pixel) == 4, "Incorrect size for Pixel");
}

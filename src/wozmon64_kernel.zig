//Copyright Daniel Bokser 2023
//See LICENSE file for permissible source code usage

pub usingnamespace @import("wozmon64_user.zig");

const w64_user = @import("wozmon64_user.zig");
const std = @import("std");
const toolbox = @import("toolbox");
const profiler = toolbox.profiler;
const amd64 = @import("amd64.zig");
const bitmaps = @import("bitmaps.zig");

pub const MMIO_PAGE_SIZE = toolbox.kb(4);
pub const PAGE_TABLE_PAGE_SIZE = toolbox.kb(4);
pub const PHYSICAL_ADDRESS_ALIGNMENT = toolbox.kb(4);

pub const KERNEL_GLOBAL_ARENA_SIZE = toolbox.mb(512);
pub const KERNEL_FRAME_ARENA_SIZE = toolbox.mb(4);
pub const KERNEL_SCRATCH_ARENA_SIZE = toolbox.mb(4);

pub const PAGE_TABLE_RECURSIVE_OFFSET = 510;
pub const KERNEL_VIRTUAL_ADDRESS_PREFIX = 0xFFFF_FFFF_8000_0000;

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
                break :b 1; //2;
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
    application_processor_kernel_entry_data: w64_user.Atomic(?struct {
        entry: *const fn (
            context: *ApplicationProcessorKernelContext,
        ) callconv(.C) noreturn,
        cr3: u64, //page table address
        stack_bottom_address: u64, //initial stack pointer
        start_context_data: *ApplicationProcessorKernelContext,
    }),
};

pub const ApplicationProcessorKernelContext = struct {
    self_pointer: *ApplicationProcessorKernelContext,
    processor_id: u64,
    stack_bottom_address: u64, //initial stack pointer
    cr3: u64, //page table address
    fsbase: u64, //fs base address
    gsbase: u64, //gs base address
    apic: amd64.APIC,
    job: w64_user.Atomic(?struct {
        entry: *const fn (user_data: ?*anyopaque) callconv(.C) void,
        user_data: ?*anyopaque,
    }) = .{ .value = null },
};

pub const TLS = struct {
    data: [w64_user.MEMORY_PAGE_SIZE]u8 align(w64_user.MEMORY_PAGE_SIZE),
    context: ApplicationProcessorKernelContext align(w64_user.MEMORY_PAGE_SIZE),
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
    stack_bottom_address: u64, //initial stack pointer
    kernel_elf_bytes: []const u8,
    boot_profiler_snapshot: profiler.State,
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

pub fn get_pdp(virtual_address: u64) *volatile amd64.PageDirectoryPointer {
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
pub fn get_pd_4kb(virtual_address: u64) *volatile amd64.PageDirectory4KB {
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
pub fn get_pd_2mb(virtual_address: u64) *volatile amd64.PageDirectory2MB {
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
pub fn get_pt(virtual_address: u64) *volatile amd64.PageTable {
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

pub fn delay_milliseconds(n: i64) void {
    const start = toolbox.now();
    while (toolbox.now().sub(start).milliseconds() < n) {
        std.atomic.spinLoopHint();
    }
}
pub fn get_processor_context() *ApplicationProcessorKernelContext {
    return asm volatile (
        \\rdgsbase %[ret]
        : [ret] "=r" (-> *ApplicationProcessorKernelContext),
    );
}

pub fn is_kernel_address(address: u64) bool {
    return (address & KERNEL_VIRTUAL_ADDRESS_PREFIX) == KERNEL_VIRTUAL_ADDRESS_PREFIX;
}
pub const StackUnwinder = struct {
    fp: u64,
    i: usize = 0,
    max_iterations: usize = 10,

    pub fn init() StackUnwinder {
        return .{
            .fp = @frameAddress(),
        };
    }
    pub fn next(self: *StackUnwinder) ?u64 {
        defer self.i += 1;
        if (self.i >= self.max_iterations or self.fp == 0 or !toolbox.is_aligned_to(self.fp, @alignOf(u64))) {
            return null;
        }
        const ip = @as(*const u64, @ptrFromInt(self.fp + @sizeOf(u64))).*;
        const new_fp = @as(*const u64, @ptrFromInt(self.fp)).*;
        if (new_fp <= self.fp) {
            return null;
        }
        self.fp = new_fp;

        //TODO: make this CALL_INSTRUCTION_SIZE optional since it doesn't
        // work well for external interrupts
        //const CALL_INSTRUCTION_SIZE = 5;
        //return ip - CALL_INSTRUCTION_SIZE;

        return ip;
    }
};

pub fn get_scratch_arena() *toolbox.Arena {
    const StaticVars = struct {
        threadlocal var scratch_arena: ?*toolbox.Arena = null;
    };
    if (StaticVars.scratch_arena == null) {
        StaticVars.scratch_arena = toolbox.Arena.init(toolbox.mb(2));
    }
    return StaticVars.scratch_arena.?;
}

comptime {
    toolbox.static_assert(@sizeOf(w64_user.Pixel) == 4, "Incorrect size for Pixel");
}

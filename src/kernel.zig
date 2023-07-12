//Copyright Daniel Bokser 2023
//See LICENSE file for permissible source code usage

const std = @import("std");
const toolbox = @import("toolbox");
const w64 = @import("wozmon64.zig");
const amd64 = @import("amd64.zig");

const CURSOR_BLINK_TIME_MS = 500;
const ENABLE_SERIAL = true;

const KernelState = struct {
    cursor_x: usize,
    cursor_y: usize,
    last_cursor_update: w64.Time,
    cursor_char: u8,

    screen: w64.Screen,
    rsdp: *amd64.ACPI2RSDP,
    mapped_memory: []w64.VirtualMemoryMapping,
    free_conventional_memory: []w64.ConventionalMemoryDescriptor,
    application_processor_contexts: []*w64.BootloaderProcessorContext,

    global_arena: toolbox.Arena,
    frame_arena: toolbox.Arena,
    scratch_arena: toolbox.Arena,
};
pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    //not set
    _ = ret_addr;
    _ = error_return_trace;

    echo_str8("{s}", .{msg});
    @memcpy(g_state.screen.frame_buffer, g_state.screen.back_buffer);
    toolbox.hang();
}

var g_state: KernelState = undefined;

export fn kernel_entry(kernel_start_context: *w64.KernelStartContext) callconv(.C) noreturn {
    @setAlignStack(256);
    {
        const frame_arena_bytes =
            kernel_start_context.global_arena.push_bytes_aligned(w64.KERNEL_FRAME_ARENA_SIZE, 8);
        const scratch_arena_bytes =
            kernel_start_context.global_arena.push_bytes_aligned(w64.KERNEL_SCRATCH_ARENA_SIZE, 8);
        w64.Time.init(kernel_start_context.tsc_mhz);

        g_state = .{
            .cursor_x = 0,
            .cursor_y = 0,
            .last_cursor_update = w64.now(),
            .cursor_char = '@',

            .screen = kernel_start_context.screen,
            .rsdp = kernel_start_context.rsdp,
            .mapped_memory = kernel_start_context.mapped_memory,
            .free_conventional_memory = kernel_start_context.free_conventional_memory,
            .application_processor_contexts = kernel_start_context.application_processor_contexts,

            .global_arena = kernel_start_context.global_arena,
            .frame_arena = toolbox.Arena.init_with_buffer(frame_arena_bytes),
            .scratch_arena = toolbox.Arena.init_with_buffer(scratch_arena_bytes),
        };
    }
    //set up GDT
    set_up_gdt();

    //set up IDT
    set_up_idt();

    //set up memory map
    {
        //TODO
        //map recursive mapping
        //0xFFFFFF00 00000000 - 0xFFFFFF7F FFFFFFFF   Page Mapping Level 1 (Page Tables)
        //0xFFFFFF7F 80000000 - 0xFFFFFF7F BFFFFFFF   Page Mapping Level 2 (Page Directories)
        //0xFFFFFF7F BFC00000 - 0xFFFFFF7F BFDFFFFF   Page Mapping Level 3 (PDPTs / Page-Directory-Pointer Tables)
        //0xFFFFFF7F BFDFE000 - 0xFFFFFF7F BFDFEFFF   Page Mapping Level 4 (PML4)

    }

    //bring processors in to kernel space
    {
        //TODO
    }

    //set up drivers
    {
        //TODO:
    }

    @memset(g_state.screen.back_buffer, .{ .data = 0 });

    echo_welcome_line("*** Wozmon64 ***\n", .{});
    {
        var bytes_free: usize = 0;
        for (g_state.free_conventional_memory) |desc| {
            bytes_free += desc.number_of_pages * w64.MEMORY_PAGE_SIZE;
        }
        echo_welcome_line("{} bytes free *** {} processors free *** {} x {} pixels free\n", .{
            bytes_free,
            g_state.application_processor_contexts.len,
            g_state.screen.width,
            g_state.screen.height,
        });
    }

    echo_str8("\\\n", .{});
    while (true) {
        draw_cursor();
        @memcpy(g_state.screen.frame_buffer, g_state.screen.back_buffer);
    }

    toolbox.hang();
}

pub fn draw_cursor() void {
    //update cursor
    {
        const now = w64.now();
        if (now.sub(g_state.last_cursor_update).milliseconds() >= CURSOR_BLINK_TIME_MS) {
            g_state.last_cursor_update = now;
            g_state.cursor_char = if (g_state.cursor_char == '@') ' ' else '@';
        }
    }

    const index = g_state.cursor_char - ' ';
    const font = g_state.screen.font;
    const bitmap = font.character_bitmap(index);
    for (0..font.height) |y| {
        const screen_y = (g_state.cursor_y * font.height) + y;
        for (0..font.width) |x| {
            const screen_x = (g_state.cursor_x * font.kerning) + x;
            g_state.screen.back_buffer[screen_y * g_state.screen.stride + screen_x] =
                bitmap[y * font.width + x];
        }
    }
}
pub fn echo_welcome_line(comptime fmt: []const u8, args: anytype) void {
    const scratch_arena = &g_state.scratch_arena;
    const arena_save_point = scratch_arena.create_save_point();
    defer scratch_arena.restore_save_point(arena_save_point);

    const str = toolbox.str8fmt(fmt, args, scratch_arena);

    toolbox.assert(
        g_state.screen.width_in_characters > str.rune_length,
        "Bad font scale. Try making it smaller",
        .{},
    );
    const padding_each_side = @divTrunc(g_state.screen.width_in_characters - str.rune_length, 2);
    const spaces = scratch_arena.push_slice(u8, padding_each_side);

    @memset(spaces, ' ');

    echo_str8("{s}{}{s}", .{ spaces, str, spaces });
    carriage_return();
}

pub fn echo_str8(comptime fmt: []const u8, args: anytype) void {
    const scratch_arena = &g_state.scratch_arena;
    const arena_save_point = scratch_arena.create_save_point();
    defer scratch_arena.restore_save_point(arena_save_point);

    const to_print = toolbox.str8fmt(fmt, args, scratch_arena);

    var it = to_print.iterator();
    while (it.next()) |rune_and_length| {
        const rune = rune_and_length.rune;
        if (rune == '\r') {
            continue;
        }
        if (rune == '\n') {
            g_state.cursor_x = 0;
            carriage_return();
            continue;
        }
        var byte = if (rune >= ' ' and rune < 128)
            std.ascii.toUpper(@intCast(rune))
        else
            '?';
        if (byte > '_') {
            byte = '?';
        }

        //output char to serial
        if (comptime ENABLE_SERIAL) {
            asm volatile (
                \\mov $0x3F8, %%dx
                \\mov %[char], %%al
                \\outb %%al, %%dx
                :
                : [char] "r" (byte),
                : "rax", "rdx"
            );
        }

        const index = byte - ' ';

        const font = g_state.screen.font;
        const bitmap = font.character_bitmap(index);

        for (0..font.height) |y| {
            const screen_y = (g_state.cursor_y * font.height) + y;
            for (0..font.width) |x| {
                const screen_x = (g_state.cursor_x * font.kerning) + x;
                g_state.screen.back_buffer[screen_y * g_state.screen.stride + screen_x] =
                    bitmap[y * font.width + x];
            }
        }
        g_state.cursor_x += 1;
        if (g_state.cursor_x >= g_state.screen.width_in_characters) {
            carriage_return();
        }
    }
}

fn carriage_return() void {
    //output new line to serial
    if (comptime ENABLE_SERIAL) {
        asm volatile (
            \\mov $0x3F8, %%dx
            \\mov $'\n', %%al
            \\outb %%al, %%dx
            ::: "rax", "rdx");
    }

    g_state.cursor_x = 0;
    g_state.cursor_y += 1;
    const font = g_state.screen.font;
    const height_in_characters = g_state.screen.height_in_characters;
    if (g_state.cursor_y >= height_in_characters) {
        for (0..g_state.screen.height_in_characters - 1) |cy| {
            const srcy = (cy + 1) * font.height;
            const desty = cy * font.height;
            const src = g_state.screen.back_buffer[srcy * g_state.screen.stride .. (srcy + font.height - 1) * g_state.screen.stride +
                g_state.screen.width];
            const dest = g_state.screen.back_buffer[desty * g_state.screen.stride .. (desty + font.height - 1) * g_state.screen.stride +
                g_state.screen.width];
            @memcpy(dest, src);
        }
        {
            const y = (height_in_characters - 1) * font.height;
            const to_blank = g_state.screen.back_buffer[y * g_state.screen.stride ..];
            @memset(to_blank, .{ .data = 0 });
        }
        g_state.cursor_y = height_in_characters - 1;
    }
}

fn set_up_gdt() void {
    //TODO
    const gdt_array = [3]amd64.GDTDescriptor{
        //null descriptor
        @bitCast(@as(u64, 0)),
        //code descriptor
        .{
            .segment_limit_bits_0_to_15 = 0xFFFF,
            .base_addr_bits_0_to_23 = 0,
            .type_bits = @intFromEnum(amd64.GDTDescriptorType.ExecuteRead),
            .is_not_system_segment = true,
            .privilege_bits = 0,
            .is_present = true,
            .segment_limit_bits_16_to_19 = 0xF,
            .is_for_long_mode_code = true,
            .is_big = false,
            .is_granular = true,
            .base_addr_bits_24_to_31 = 0,
        },
        //data segment
        .{
            .segment_limit_bits_0_to_15 = 0xFFFF,
            .base_addr_bits_0_to_23 = 0,
            .type_bits = @intFromEnum(amd64.GDTDescriptorType.ReadWrite),
            .is_not_system_segment = true,
            .privilege_bits = 0,
            .is_present = true,
            .segment_limit_bits_16_to_19 = 0xF,
            .is_for_long_mode_code = false,
            .is_big = true,
            .is_granular = true,
            .base_addr_bits_24_to_31 = 0,
        },
    };
    const gdt = g_state.global_arena.push_slice(amd64.GDTDescriptor, gdt_array.len);
    @memcpy(gdt, gdt_array[0..]);

    const gdt_register = amd64.GDTRegister{
        .limit = @sizeOf(@TypeOf(gdt_array)) - 1,
        .gdt = gdt.ptr,
    };
    var ljmp_operand: [16]u8 = undefined;
    asm volatile (
        \\lgdt (%[gdtr])
        \\movw $0x10, %%ax
        \\movw %%ax, %%ds
        \\movw %%ax, %%es
        \\movw %%ax, %%ss
        \\movw $0, %%ax
        \\movw %%ax, %%fs #TODO: TLS
        \\movw %%ax, %%gs
        \\pushq $8
        \\lea .long_jump(%%rip), %%rax
        \\pushq %%rax
        \\lretq
        \\.long_jump:
        :
        : [limit] "r" (gdt_register.limit),
          [gdt] "r" (@intFromPtr(gdt_register.gdt)),
          [gdtr] "r" (&gdt_register),
          [ljmp_operand] "r" (&ljmp_operand),
        : "rax"
    );
}

fn set_up_idt() void {
    var idt = g_state.global_arena.push_slice_clear(amd64.IDTDescriptor, 256);
    const idt_register = amd64.IDTRegister{
        .limit = @intCast(idt.len - 1),
        .idt = idt.ptr,
    };
    amd64.register_exception_handler(&invalid_opcode_handler, .InvalidOpcode, idt);
    asm volatile (
        \\lidt (%[idtr])
        :
        : [idtr] "r" (&idt_register),
    );
}

fn invalid_opcode_handler() callconv(.Interrupt) void {
    toolbox.panic("Invalid opcode!", .{});
}

//for debugging within print routines
fn print_serial(comptime fmt: []const u8, args: anytype) void {
    const scratch_arena = &g_state.scratch_arena;
    const arena_save_point = scratch_arena.create_save_point();
    defer scratch_arena.restore_save_point(arena_save_point);
    const to_print = toolbox.str8fmt(fmt, args, scratch_arena);

    for (to_print.bytes) |byte| {
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

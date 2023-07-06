//Copyright Daniel Bokser 2023
//See LICENSE file for permissible source code usage

const std = @import("std");
const toolbox = @import("toolbox");
const w64 = @import("wozmon64.zig");
const amd64 = @import("amd64.zig");

const PROMPT_BLINK_TIME_MS = 500;
const KernelState = struct {
    cursor_x: usize,
    cursor_y: usize,
    last_prompt_update: w64.Time,
    prompt_char: u8,

    screen: w64.Screen,
    rsdp: *amd64.ACPI2RSDP,
    mapped_memory: []w64.VirtualMemoryMapping,
    free_conventional_memory: []w64.ConventionalMemoryDescriptor,
    application_processor_contexts: []*w64.BootloaderProcessorContext,

    global_arena: toolbox.Arena,
    frame_arena: toolbox.Arena,
    scratch_arena: toolbox.Arena,
};

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
            .last_prompt_update = w64.now(),
            .prompt_char = '@',

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
    {
        //TODO
    }

    //set up IDT
    {
        //TODO
    }

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
        draw_prompt();
        @memcpy(g_state.screen.frame_buffer, g_state.screen.back_buffer);
    }

    toolbox.hang();
}

pub fn draw_prompt() void {
    //update prompt
    {
        const now = w64.now();
        if (now.sub(g_state.last_prompt_update).milliseconds() >= PROMPT_BLINK_TIME_MS) {
            g_state.last_prompt_update = now;
            g_state.prompt_char = if (g_state.prompt_char == '@') ' ' else '@';
        }
    }

    const index = g_state.prompt_char - ' ';
    const bitmap = w64.CHARACTERS[index];
    for (0..w64.CharacterBitmap.HEIGHT) |y| {
        const screen_y = (g_state.cursor_y * w64.CharacterBitmap.HEIGHT) + y;
        for (0..w64.CharacterBitmap.WIDTH) |x| {
            const screen_x = (g_state.cursor_x * w64.CharacterBitmap.KERNING) + x;
            g_state.screen.back_buffer[screen_y * g_state.screen.stride + screen_x] =
                bitmap.pixels[y * w64.CharacterBitmap.WIDTH + x];
        }
    }
}
pub fn echo_welcome_line(comptime fmt: []const u8, args: anytype) void {
    const scratch_arena = &g_state.scratch_arena;
    const arena_save_point = scratch_arena.create_save_point();
    defer scratch_arena.restore_save_point(arena_save_point);

    const str = toolbox.str8fmt(fmt, args, scratch_arena);

    const screen_midpont = @divTrunc(w64.SCREEN_CHARACTER_RESOLUTION.width, 2);
    _ = screen_midpont;

    const padding_each_side = @divTrunc((w64.SCREEN_CHARACTER_RESOLUTION.width - str.rune_length), 2);
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
        const index = byte - ' ';

        const bitmap = w64.CHARACTERS[index];
        for (0..w64.CharacterBitmap.HEIGHT) |y| {
            const screen_y = (g_state.cursor_y * w64.CharacterBitmap.HEIGHT) + y;
            for (0..w64.CharacterBitmap.WIDTH) |x| {
                const screen_x = (g_state.cursor_x * w64.CharacterBitmap.KERNING) + x;
                g_state.screen.back_buffer[screen_y * g_state.screen.stride + screen_x] =
                    bitmap.pixels[y * w64.CharacterBitmap.WIDTH + x];
            }
        }
        g_state.cursor_x += 1;
        if (g_state.cursor_x >= w64.SCREEN_CHARACTER_RESOLUTION.width) {
            carriage_return();
        }
    }
}

fn carriage_return() void {
    g_state.cursor_x = 0;
    g_state.cursor_y += 1;
    if (g_state.cursor_y >= w64.SCREEN_CHARACTER_RESOLUTION.height) {
        for (0..w64.SCREEN_CHARACTER_RESOLUTION.height - 1) |cy| {
            const srcy = (cy + 1) * w64.CharacterBitmap.HEIGHT;
            const desty = cy * w64.CharacterBitmap.HEIGHT;
            const src = g_state.screen.back_buffer[srcy * g_state.screen.stride .. (srcy + w64.CharacterBitmap.HEIGHT - 1) * g_state.screen.stride +
                g_state.screen.width];
            const dest = g_state.screen.back_buffer[desty * g_state.screen.stride .. (desty + w64.CharacterBitmap.HEIGHT - 1) * g_state.screen.stride +
                g_state.screen.width];
            @memcpy(dest, src);
        }
        {
            const y = (w64.SCREEN_CHARACTER_RESOLUTION.height - 1) * w64.CharacterBitmap.HEIGHT;
            const to_blank = g_state.screen.back_buffer[y * g_state.screen.stride ..];
            @memset(to_blank, .{ .data = 0 });
        }
        g_state.cursor_y = w64.SCREEN_CHARACTER_RESOLUTION.height - 1;
    }
}

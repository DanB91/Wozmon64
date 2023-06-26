//Screen can fit 53x20 characters
//should only be called by BSP (main processor) and before getMemoryMap
const std = @import("std");
const w64 = @import("wozmon64.zig");
const toolbox = @import("toolbox");

const ENABLE_CONSOLE = true;
const BootloaderStage = enum {
    UEFI,
    AfterExitButBeforeScreenIsSetup,
    GraphicsConsole,
};
const State = struct {
    screen: w64.Screen,
    stage: BootloaderStage = .UEFI,
    cursor_x: usize = 0,
    cursor_y: usize = 0,
    lock: toolbox.TicketLock = .{},
};

var g_state = State{ .screen = undefined };
const MAX_BYTES = 512;

pub fn println(comptime fmt: []const u8, args: anytype) void {
    g_state.lock.lock();
    defer g_state.lock.release();
    switch (g_state.stage) {
        .UEFI => uefi_println(fmt, args),
        .AfterExitButBeforeScreenIsSetup => serial_println(fmt, args),
        .GraphicsConsole => graphics_println(fmt, args),
    }
}

pub fn exit_boot_services() void {
    g_state.stage = .AfterExitButBeforeScreenIsSetup;
}

pub fn init_graphics_console(screen: w64.Screen) void {
    g_state = State{
        .screen = screen,
        .stage = .GraphicsConsole,
        .cursor_x = 0,
        .cursor_y = 0,
    };
}
fn graphics_println(comptime fmt: []const u8, args: anytype) void {
    if (comptime !ENABLE_CONSOLE) {
        return;
    }
    serial_println(fmt, args);

    var buf: [MAX_BYTES]u8 = undefined;
    const utf8 =
        toolbox.str8(std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch buf[0..]);
    var it = utf8.iterator();
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
            std.ascii.toUpper(@intCast(u8, rune))
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
    @memcpy(g_state.screen.frame_buffer, g_state.screen.back_buffer);
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

fn uefi_println(comptime fmt: []const u8, args: anytype) void {
    if (comptime !ENABLE_CONSOLE) {
        return;
    }
    var buf8: [MAX_BYTES:0]u8 = undefined;
    var buf16: [MAX_BYTES:0]u16 = [_:0]u16{0} ** MAX_BYTES;
    const utf8 = std.fmt.bufPrintZ(&buf8, fmt ++ "\r\n", args) catch buf8[0..];
    _ = std.unicode.utf8ToUtf16Le(&buf16, utf8) catch return;
    _ = std.os.uefi.system_table.con_out.?.outputString(&buf16);
}

fn serial_println(comptime fmt: []const u8, args: anytype) void {
    if (comptime !ENABLE_CONSOLE) {
        return;
    }
    const COM1_PORT_ADDRESS = 0x3F8;
    var buf: [MAX_BYTES]u8 = undefined;
    const bytes = std.fmt.bufPrint(&buf, fmt ++ "\r\n", args) catch buf[0..];
    for (bytes) |b| {
        asm volatile (
            \\outb %%al, %%dx
            :
            : [data] "{al}" (b),
              [port] "{dx}" (COM1_PORT_ADDRESS),
            : "rax", "rdx"
        );
    }
}

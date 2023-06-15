//Copyright Daniel Bokser 2023
//See LICENSE file for permissible source code usage

const std = @import("std");
const toolbox = @import("toolbox");
const w64 = @import("wozmon64.zig");

export fn kernel_entry(kernel_start_context: *w64.KernelStartContext) callconv(.C) noreturn {
    @setAlignStack(256);
    while (true) {
        for (0..0xFFFF_FFFF) |i| {
            @memset(kernel_start_context.screen.back_buffer, .{ .data = @intCast(u32, i) });
            @memcpy(kernel_start_context.screen.frame_buffer, kernel_start_context.screen.back_buffer);
        }
    }

    toolbox.hang();
}

fn serial_println(comptime fmt: []const u8, args: anytype) void {
    const ENABLE_CONSOLE = true;
    const MAX_BYTES = 512;
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

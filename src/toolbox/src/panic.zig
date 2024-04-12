const std = @import("std");
const builtin = @import("builtin");
const toolbox = @import("toolbox.zig");

pub const panic_handler = if (toolbox.THIS_PLATFORM != .Playdate)
    std.builtin.default_panic
else
    playdate_panic;

pub fn playdate_panic(
    msg: []const u8,
    error_return_trace: ?*std.builtin.StackTrace,
    return_address: ?usize,
) noreturn {
    _ = error_return_trace;
    _ = return_address;

    switch (comptime builtin.os.tag) {
        .freestanding => {
            //playdate hardware
            //TODO figure out stack unwinding.
            //Frame pointer is R7
            //Next Frame pointer is *R7
            //Return address is *(R7+4)
            //We need to know the load address and it doesn't seem to be exactly
            //0x6000_0000 as originally thought

            toolbox.playdate_error("PANIC: %s", msg.ptr);
        },
        else => {
            //playdate simulator
            if (toolbox.IS_DEBUG) {
                @breakpoint();
            }
            var stack_trace_buffer = [_]u8{0} ** 4096;
            var buffer = [_]u8{0} ** 4096;
            var stream = std.io.fixedBufferStream(&stack_trace_buffer);

            b: {
                if (builtin.strip_debug_info) {
                    const to_print = std.fmt.bufPrintZ(&buffer, "Unable to dump stack trace: debug info stripped\n", .{}) catch return;
                    toolbox.playdate_error("%s", to_print.ptr);
                    break :b;
                }
                const debug_info = std.debug.getSelfDebugInfo() catch |err| {
                    const to_print = std.fmt.bufPrintZ(&buffer, "Unable to dump stack trace: Unable to open debug info: {s}\n", .{@errorName(err)}) catch break :b;
                    toolbox.playdate_error("%s", to_print.ptr);
                    break :b;
                };
                std.debug.writeCurrentStackTrace(stream.writer(), debug_info, .no_color, null) catch {};
            }
            const to_print = std.fmt.bufPrintZ(&buffer, "{s} -- {s}", .{ msg, stack_trace_buffer[0..stream.pos] }) catch "Unknown error";
            toolbox.playdate_error("%s", to_print.ptr);
        },
    }

    while (true) {}
}

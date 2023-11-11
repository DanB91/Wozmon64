const std = @import("std");
const toolbox = @import("toolbox.zig");

extern fn write(filedes: c_int, buffer: ?*anyopaque, len: usize) isize;
pub fn println_str8(string: toolbox.String8) void {
    platform_print_to_console("{s}", .{string.bytes}, false, true);
}
pub fn print_str8(string: toolbox.String8) void {
    platform_print_to_console("{s}", .{string.bytes}, false, false);
}
pub fn println(comptime fmt: []const u8, args: anytype) void {
    platform_print_to_console(fmt, args, false, true);
}
pub fn print(comptime fmt: []const u8, args: anytype) void {
    platform_print_to_console(fmt, args, false, false);
}
pub fn printerr(comptime fmt: []const u8, args: anytype) void {
    platform_print_to_console(fmt, args, true, true);
}

pub fn panic(comptime fmt: []const u8, args: anytype) noreturn {
    var buffer = [_]u8{0} ** 2048;
    const to_print = std.fmt.bufPrint(&buffer, "PANIC: " ++ fmt ++ "\n", args) catch "Unknown error!";
    @panic(to_print);
}

fn platform_print_to_console(comptime fmt: []const u8, args: anytype, comptime is_err: bool, comptime include_newline: bool) void {
    const nl = if (include_newline) "\n" else "";
    switch (comptime toolbox.THIS_PLATFORM) {
        .WASM, .MacOS => {
            var buffer = [_]u8{0} ** 2048;
            //TODO dynamically allocate buffer for printing.  use std.fmt.count to count the size

            const to_print = if (is_err)
                std.fmt.bufPrint(&buffer, "ERROR: " ++ fmt ++ nl, args) catch return
            else
                std.fmt.bufPrint(&buffer, fmt ++ nl, args) catch return;

            _ = write(if (is_err) 2 else 1, to_print.ptr, to_print.len);
        },
        .Playdate => {
            var buffer = [_]u8{0} ** 128;
            const to_print = if (is_err)
                std.fmt.bufPrintZ(&buffer, "ERROR: " ++ fmt, args) catch {
                    toolbox.playdate_log_to_console("String too long to print");
                    return;
                }
            else
                std.fmt.bufPrintZ(&buffer, fmt, args) catch {
                    toolbox.playdate_log_to_console("String too long to print");
                    return;
                };
            toolbox.playdate_log_to_console("%s", to_print.ptr);
        },
        else => @compileError("Unsupported platform"),
    }
    //TODO support BoksOS
    //TODO think about stderr
    //TODO won't work on windows
}

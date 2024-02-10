const std = @import("std");
const w64 = @import("wozmon64");
const toolbox = @import("toolbox");
const WOZ_AND_JOBS = @embedFile("woz-and-jobs.rgb");
const WOZ_AND_JOBS_WIDTH = 465;
const WOZ_AND_JOBS_HEIGHT = WOZ_AND_JOBS.len / (WOZ_AND_JOBS_WIDTH * 3);

var g_system_api: *const w64.ProgramContext = undefined;
var arena_bytes = [_]u8{0} ** toolbox.mb(16);

pub const THIS_PLATFORM = toolbox.Platform.Wozmon64;

pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    _ = ret_addr;
    _ = error_return_trace;
    g_system_api.error_and_terminate(msg.ptr, msg.len);
}

export fn entry(system_api: *const w64.ProgramContext) linksection(".entry") void {
    g_system_api = system_api;

    const screen_width = w64.SCREEN_PIXEL_WIDTH_PTR.*;
    const screen_height = w64.SCREEN_PIXEL_HEIGHT_PTR.*;
    const stride = w64.FRAME_BUFFER_STRIDE_PTR.*;
    const frame_buffer = w64.FRAME_BUFFER_PTR[0 .. stride * screen_height];

    var arena = toolbox.Arena.init_with_buffer(&arena_bytes);
    var key_events = w64.KeyEvents.init(arena);

    var x_pos: i64 = @intCast(screen_width / 2 - WOZ_AND_JOBS_WIDTH / 2);
    var y_pos: i64 = @intCast(screen_height / 2 - WOZ_AND_JOBS_HEIGHT / 2);
    var vx: i64 = 0;
    var vy: i64 = 0;
    system_api.register_key_events_queue(&key_events);

    const back_buffer = arena.push_slice(w64.Pixel, frame_buffer.len);

    while (true) {
        //process input
        {
            while (key_events.key_pressed_events.dequeue()) |scancode| {
                w64.println_serial("Key pressed: {}", .{scancode});
                switch (scancode) {
                    .UpArrow => vy = -1,
                    .DownArrow => vy = 1,
                    .LeftArrow => vx = -1,
                    .RightArrow => vx = 1,
                    else => {},
                }
            }
            while (key_events.key_released_events.dequeue()) |scancode| {
                w64.println_serial("Key released: {}", .{scancode});
                switch (scancode) {
                    .UpArrow, .DownArrow => vy = 0,
                    .LeftArrow, .RightArrow => vx = 0,
                    else => {},
                }
            }
            x_pos += vx * 4;
            y_pos += vy * 4;
            x_pos = toolbox.clamp(x_pos, 0, @intCast(screen_width - WOZ_AND_JOBS_WIDTH - 1));
            y_pos = toolbox.clamp(y_pos, 0, @intCast(screen_height - WOZ_AND_JOBS_HEIGHT - 1));
        }
        @memset(back_buffer, .{ .data = 0 });

        for (0..WOZ_AND_JOBS_HEIGHT) |y| {
            for (0..WOZ_AND_JOBS_WIDTH) |x| {
                const pixel = y * 3 * WOZ_AND_JOBS_WIDTH + x * 3;
                const r = WOZ_AND_JOBS[pixel];
                const g = WOZ_AND_JOBS[pixel + 1];
                const b = WOZ_AND_JOBS[pixel + 2];
                back_buffer[
                    (y + @as(usize, @intCast(y_pos))) * stride +
                        (x + @as(usize, @intCast(x_pos)))
                ] = .{
                    .colors = .{
                        .r = r,
                        .g = g,
                        .b = b,
                    },
                };
            }
        }
        @memcpy(frame_buffer, back_buffer);
    }
}

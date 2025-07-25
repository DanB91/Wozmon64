const std = @import("std");
const w64 = @import("wozmon64");
const toolbox = @import("toolbox");

const doom = @cImport({
    @cInclude("PureDoom.h");
});
const DOOM1_WAD = @embedFile("doom1.wad");

pub const THIS_PLATFORM = toolbox.Platform.Wozmon64;

const PlatformState = struct {
    program_context: *const w64.ProgramContext = undefined,
    global_arena_store: [toolbox.mb(16)]u8 = undefined,
    is_shift_key_down: bool = false,
    global_arena: *toolbox.Arena = undefined,
};

const FileState = struct {
    data: []const u8 = @as([*]u8, undefined)[0..0],
    pos: usize = 0,
    name: []const u8 = @as([*]u8, undefined)[0..0],
};

var g_state: PlatformState = .{};

pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    _ = ret_addr;
    _ = error_return_trace;
    g_state.program_context.error_and_terminate(msg.ptr, msg.len);
}

export fn entry(program_context: *const w64.ProgramContext) linksection(".entry") void {
    toolbox.amd64_ticks_to_microseconds = program_context.tsc_mhz;

    g_state = .{
        .program_context = program_context,
    };
    g_state.global_arena = toolbox.Arena.init_with_buffer(&g_state.global_arena_store);
    const screen_width = w64.SCREEN_PIXEL_WIDTH_PTR.*;
    const screen_height = w64.SCREEN_PIXEL_HEIGHT_PTR.*;
    const stride = w64.FRAME_BUFFER_STRIDE_PTR.*;
    const frame_buffer = w64.FRAME_BUFFER_PTR[0 .. stride * screen_height];

    var key_events = w64.KeyEvents.init(g_state.global_arena);
    g_state.program_context.register_key_events_queue(&key_events);

    doom.doom_set_print(doom_print);
    doom.doom_set_exit(doom_exit);
    doom.doom_set_getenv(doom_getenv);
    doom.doom_set_malloc(doom_malloc, doom_free);
    doom.doom_set_gettime(doom_gettime);
    doom.doom_set_file_io(
        doom_open,
        doom_close,
        doom_read,
        doom_write,
        doom_seek,
        doom_tell,
        doom_eof,
    );
    doom.doom_init(0, null, 0);

    @memset(frame_buffer, .{ .data = 0 });

    const scale = @min(
        @divTrunc(screen_height, doom.SCREENHEIGHT),
        @divTrunc(screen_width, doom.SCREENWIDTH),
    );
    const scaled_width = doom.SCREENWIDTH * scale;
    const scaled_height = doom.SCREENHEIGHT * scale;
    const offset_x = @divTrunc((screen_width - scaled_width), 2);
    const offset_y = @divTrunc((screen_height - scaled_height), 2);
    while (true) {
        process_input(&key_events);
        doom.doom_update();

        {
            const doom_pixels = doom.doom_get_framebuffer(1);
            for (0..doom.SCREENHEIGHT) |sy| {
                for (0..doom.SCREENWIDTH) |sx| {
                    const palette_index = @as(usize, doom_pixels[sy * doom.SCREENWIDTH + sx]) * 3;
                    const pixel = w64.Pixel{
                        .colors = .{
                            .r = doom.screen_palette[palette_index],
                            .g = doom.screen_palette[palette_index + 1],
                            .b = doom.screen_palette[palette_index + 2],
                        },
                    };
                    const dy = sy * scale;
                    const dx = sx * scale;
                    draw_scaled_pixel(
                        pixel,
                        frame_buffer,
                        stride,
                        offset_x + dx,
                        offset_y + dy,
                        scale,
                    );
                }
            }
        }
    }
}

fn draw_scaled_pixel(
    pixel: w64.Pixel,
    frame_buffer: []w64.Pixel,
    stride: usize,
    x: usize,
    y: usize,
    scale: usize,
) void {
    for (0..scale) |scale_y| {
        for (0..scale) |scale_x| {
            frame_buffer[(y + scale_y) * stride + (x + scale_x)] = pixel;
        }
    }
}

fn process_input(key_events: *w64.KeyEvents) void {
    while (key_events.modifier_key_pressed_events.dequeue()) |scancode| {
        switch (scancode) {
            .LeftShift, .RightShift => g_state.is_shift_key_down = true,
            else => {},
        }
        doom.doom_key_down(scancode_to_doom_key(scancode, g_state.is_shift_key_down));
    }
    while (key_events.modifier_key_released_events.dequeue()) |scancode| {
        switch (scancode) {
            .LeftShift, .RightShift => g_state.is_shift_key_down = false,
            else => {},
        }
        doom.doom_key_up(scancode_to_doom_key(scancode, g_state.is_shift_key_down));
    }
    while (key_events.key_pressed_events.dequeue()) |scancode| {
        doom.doom_key_down(scancode_to_doom_key(
            scancode,
            g_state.is_shift_key_down,
        ));
    }
    while (key_events.key_released_events.dequeue()) |scancode| {
        doom.doom_key_up(scancode_to_doom_key(
            scancode,
            g_state.is_shift_key_down,
        ));
    }
}

fn scancode_to_doom_key(scancode: w64.ScanCode, is_shift_key_down: bool) doom.doom_key_t {
    return switch (scancode) {
        .Enter => doom.DOOM_KEY_ENTER,
        .Escape => doom.DOOM_KEY_ESCAPE,
        .UpArrow => doom.DOOM_KEY_UP_ARROW,
        .DownArrow => doom.DOOM_KEY_DOWN_ARROW,
        .LeftArrow => doom.DOOM_KEY_LEFT_ARROW,
        .RightArrow => doom.DOOM_KEY_RIGHT_ARROW,
        .Space => doom.DOOM_KEY_SPACE,
        .Tab => doom.DOOM_KEY_TAB,
        .Quote => doom.DOOM_KEY_APOSTROPHE,
        .Comma => doom.DOOM_KEY_COMMA,
        .Hyphen => doom.DOOM_KEY_MINUS,
        .Period => doom.DOOM_KEY_PERIOD,
        .Slash => doom.DOOM_KEY_SLASH,
        .Zero => doom.DOOM_KEY_0,
        .One => doom.DOOM_KEY_1,
        .Two => doom.DOOM_KEY_2,
        .Three => doom.DOOM_KEY_3,
        .Four => doom.DOOM_KEY_4,
        .Five => doom.DOOM_KEY_5,
        .Six => doom.DOOM_KEY_6,
        .Seven => doom.DOOM_KEY_7,
        .Eight => if (is_shift_key_down) doom.DOOM_KEY_MULTIPLY else doom.DOOM_KEY_8,
        .Nine => doom.DOOM_KEY_9,
        .Semicolon => doom.DOOM_KEY_SEMICOLON,
        .Equals => doom.DOOM_KEY_EQUALS,
        .LeftBracket => doom.DOOM_KEY_LEFT_BRACKET,
        .RightBracket => doom.DOOM_KEY_RIGHT_BRACKET,
        .A => doom.DOOM_KEY_A,
        .B => doom.DOOM_KEY_B,
        .C => doom.DOOM_KEY_C,
        .D => doom.DOOM_KEY_D,
        .E => doom.DOOM_KEY_E,
        .F => doom.DOOM_KEY_F,
        .G => doom.DOOM_KEY_G,
        .H => doom.DOOM_KEY_H,
        .I => doom.DOOM_KEY_I,
        .J => doom.DOOM_KEY_J,
        .K => doom.DOOM_KEY_K,
        .L => doom.DOOM_KEY_L,
        .M => doom.DOOM_KEY_M,
        .N => doom.DOOM_KEY_N,
        .O => doom.DOOM_KEY_O,
        .P => doom.DOOM_KEY_P,
        .Q => doom.DOOM_KEY_Q,
        .R => doom.DOOM_KEY_R,
        .S => doom.DOOM_KEY_S,
        .T => doom.DOOM_KEY_T,
        .U => doom.DOOM_KEY_U,
        .V => doom.DOOM_KEY_V,
        .W => doom.DOOM_KEY_W,
        .X => doom.DOOM_KEY_X,
        .Y => doom.DOOM_KEY_Y,
        .Z => doom.DOOM_KEY_Z,
        .Backspace => doom.DOOM_KEY_BACKSPACE,
        .LeftCtrl, .RightCtrl => doom.DOOM_KEY_CTRL,
        .LeftShift, .RightShift => doom.DOOM_KEY_SHIFT,
        .LeftAlt, .RightAlt => doom.DOOM_KEY_ALT,
        .F1 => doom.DOOM_KEY_F1,
        .F2 => doom.DOOM_KEY_F2,
        .F3 => doom.DOOM_KEY_F3,
        .F4 => doom.DOOM_KEY_F4,
        .F5 => doom.DOOM_KEY_F5,
        .F6 => doom.DOOM_KEY_F6,
        .F7 => doom.DOOM_KEY_F7,
        .F8 => doom.DOOM_KEY_F8,
        .F9 => doom.DOOM_KEY_F9,
        .F10 => doom.DOOM_KEY_F10,
        .F11 => doom.DOOM_KEY_F11,
        .F12 => doom.DOOM_KEY_F12,
        .Pause => doom.DOOM_KEY_PAUSE,
        else => doom.DOOM_KEY_UNKNOWN,
    };
}

fn doom_read(handle: ?*anyopaque, buffer_c: ?*anyopaque, count: c_int) callconv(.C) c_int {
    if (handle == null) {
        return -1;
    }
    const file: *FileState = @ptrCast(@alignCast(handle));
    const buffer = @as([*]u8, @ptrCast(buffer_c))[0..@intCast(count)];
    const n_bytes_to_copy = @min(buffer.len, file.data.len - file.pos);
    @memcpy(buffer[0..n_bytes_to_copy], file.data[file.pos .. file.pos + n_bytes_to_copy]);
    file.pos += n_bytes_to_copy;
    return @intCast(n_bytes_to_copy);
}

fn doom_seek(handle: ?*anyopaque, offset: c_int, origin: doom.doom_seek_t) callconv(.C) c_int {
    if (handle == null) {
        return -1;
    }
    const file: *FileState = @ptrCast(@alignCast(handle));
    const signed_pos: c_int = @intCast(file.pos);
    const signed_len: c_int = @intCast(file.data.len);
    const potential_position = switch (origin) {
        doom.DOOM_SEEK_SET => offset,
        doom.DOOM_SEEK_CUR => signed_pos + offset,
        doom.DOOM_SEEK_END => signed_len - offset,
        else => return -1,
    };
    if (potential_position >= 0 or potential_position <= file.data.len) {
        file.pos = @intCast(potential_position);
        return 0;
    }
    return -1;
}
fn doom_tell(handle: ?*anyopaque) callconv(.C) c_int {
    if (handle == null) {
        return -1;
    }
    const file: *FileState = @ptrCast(@alignCast(handle));
    return @intCast(file.pos);
}
fn doom_eof(handle: ?*anyopaque) callconv(.C) c_int {
    if (handle == null) {
        return 0;
    }
    const file: *FileState = @ptrCast(@alignCast(handle));
    return if (file.pos >= file.data.len) 1 else 0;
}

fn doom_open(filename_c: [*c]const u8, _: [*c]const u8) callconv(.C) ?*anyopaque {
    const filename = std.mem.span(filename_c);
    w64.println_serial("Trying to open {s}", .{filename});
    if (std.mem.eql(u8, filename, "./doom1.wad")) {
        const file = g_state.global_arena.push(FileState);
        file.* = .{
            .data = DOOM1_WAD,
            .name = filename,
            .pos = 0,
        };
        return file;
    }
    return null;
}

fn doom_close(_: ?*anyopaque) callconv(.C) void {
    //do nothing
}

fn doom_write(handle: ?*anyopaque, buffer_c: ?*const anyopaque, count: c_int) callconv(.C) c_int {
    _ = handle; // autofix
    _ = buffer_c; // autofix
    _ = count; // autofix
    //TODO: implement
    return 0;
}

fn doom_exit(_: c_int) callconv(.C) void {
    g_state.program_context.terminate();
}

fn doom_getenv(name_c: [*c]const u8) callconv(.C) [*c]u8 {
    const name = std.mem.span(name_c);
    if (std.mem.eql(u8, name, "HOME")) {
        return @ptrFromInt(@intFromPtr(".".ptr));
    }
    return null;
}

fn doom_print(str: [*c]const u8) callconv(.C) void {
    w64.print_serial("{s}", .{str});
}
fn doom_malloc(size: c_int) callconv(.C) ?*anyopaque {
    return g_state.global_arena.push_bytes_aligned(@intCast(size), 16).ptr;
}
fn doom_free(_: ?*anyopaque) callconv(.C) void {
    //do nothing
}

fn doom_gettime(sec: ?*c_int, usec: ?*c_int) callconv(.C) void {
    const now = toolbox.now();
    const large_seconds: i64 = @divTrunc(now.microseconds(), 1_000_000);
    sec.?.* = @intCast(large_seconds);
    usec.?.* = @intCast(now.microseconds() - large_seconds * 1_000_000);
}

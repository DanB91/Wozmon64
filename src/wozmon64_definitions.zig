//Copyright Daniel Bokser 2023
//See LICENSE file for permissible source code usage

const toolbox = @import("toolbox");
pub usingnamespace @import("bitmaps.zig");

//TODO change to 1920
pub const TARGET_RESOLUTION = .{
    .width = 1280,
    .height = 720,
    // .width = 3840,
    // .height = 2160,
};

pub const Pixel = packed union {
    colors: packed struct(u32) {
        b: u8,
        g: u8,
        r: u8,
        reserved: u8 = 0,
    },
    data: u32,
};

pub const Screen = struct {
    frame_buffer: []volatile Pixel,
    back_buffer: []Pixel,
    width: usize,
    height: usize,
    stride: usize,
};

comptime {
    toolbox.static_assert(@sizeOf(Pixel) == 4, "Incorrect size for Pixel");
}

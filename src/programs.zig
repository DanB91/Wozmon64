const w64 = @import("wozmon64.zig");

pub const woz_and_jobs = @embedFile("../zig-out/bin/woz_and_jobs.bin");
pub const draw_flashing_screen = [_]u8{
    0x48,
    0x8B,
    0x04,
    0x25,
    0x40,
    0x00,
    0x20,
    0x02,
    0x31,
    0xD2,
    0x48,
    0x8D,
    0x0C,
    0x85,
    0x00,
    0x00,
    0x20,
    0x00,
    0x48,
    0x85,
    0xC0,
    0x75,
    0x1A,
    0xEB,
    0xFE,
    0x89,
    0x14,
    0x25,
    0x00,
    0x00,
    0x20,
    0x00,
    0xB8,
    0x04,
    0x00,
    0x20,
    0x00,
    0x48,
    0x81,
    0xF9,
    0x04,
    0x00,
    0x20,
    0x00,
    0x75,
    0x0D,
    0x83,
    0xC2,
    0x01,
    0xB8,
    0x00,
    0x00,
    0x20,
    0x00,
    0xF6,
    0xC1,
    0x04,
    0x75,
    0xDE,
    0x89,
    0x10,
    0x48,
    0x83,
    0xC0,
    0x08,
    0x89,
    0x50,
    0xFC,
    0x48,
    0x39,
    0xC1,
    0x75,
    0xF2,
    0x83,
    0xC2,
    0x01,
    0xEB,
    0xE3,
};
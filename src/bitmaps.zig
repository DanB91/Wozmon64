const w64 = @import("wozmon64_definitions.zig");

pub const SCREEN_CHARACTER_RESOLUTION = .{
    .width = w64.TARGET_RESOLUTION.width / CharacterBitmap.KERNING,
    .height = w64.TARGET_RESOLUTION.height / CharacterBitmap.HEIGHT,
};
pub const CharacterBitmap = struct {
    pixels: [SCALE * CHARACTER_HEIGHT * SCALE * CHARACTER_WIDTH]w64.Pixel,
    pub const WIDTH = CHARACTER_WIDTH * SCALE;
    pub const HEIGHT = CHARACTER_HEIGHT * SCALE;
    pub const KERNING = WIDTH + SCALE;
};

pub const CHARACTERS: [PRESCALED_CHARACTERS.len]CharacterBitmap = b: {
    const BACKGROUND_COLOR = w64.Pixel{ .data = 0 };
    const TEXT_COLOR = w64.Pixel{ .colors = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } };
    var ret: [PRESCALED_CHARACTERS.len]CharacterBitmap = undefined;
    for (PRESCALED_CHARACTERS, 0..) |char, i| {
        for (char, 0..) |row, cy| {
            for (0..CHARACTER_WIDTH, 0..) |column, cx| {
                @setEvalBranchQuota(100000);
                const shift = (CHARACTER_WIDTH - 1 - column);
                const pixel: w64.Pixel = if (row & (1 << shift) != 0)
                    TEXT_COLOR
                else
                    BACKGROUND_COLOR;
                for (0..SCALE) |dy| {
                    for (0..SCALE) |dx| {
                        ret[i].pixels[(cy * SCALE + dy) * CharacterBitmap.WIDTH + (cx * SCALE + dx)] = pixel;
                    }
                }
            }
        }
    }

    break :b ret;
};
const SCALE = b: {
    if (w64.TARGET_RESOLUTION.width == 1920 and w64.TARGET_RESOLUTION.height == 1080) {
        break :b 6;
    } else if (w64.TARGET_RESOLUTION.width == 1280 and w64.TARGET_RESOLUTION.height == 720) {
        break :b 2; //4;
    } else {
        @compileError("Unsupported resolution");
    }
};
// const SCALE = 1;

const CHARACTER_WIDTH = 5;
const CHARACTER_HEIGHT = 8;

//Taken from https://www.applefritter.com/files/signetics2513.pdf
//NOTE: It seems the Signetics 2513 had a strange interpetation of ASCII
//      in that '@' thru '_' was before ' ' thru '?'.
//      Wozmon64 uses the correct ASCII ordering

const PRESCALED_CHARACTERS = [_][8]u8{
    .{ //space
        0b00000,
        0b00000,
        0b00000,
        0b00000,
        0b00000,
        0b00000,
        0b00000,
        0b00000,
    },
    .{ // !
        0b00000,
        0b00100,
        0b00100,
        0b00100,
        0b00100,
        0b00100,
        0b00000,
        0b00100,
    },
    .{ //"
        0b00000,
        0b01010,
        0b01010,
        0b01010,
        0b00000,
        0b00000,
        0b00000,
        0b00000,
    },
    .{ //#
        0b00000,
        0b01010,
        0b01010,
        0b11111,
        0b01010,
        0b11111,
        0b01010,
        0b01010,
    },
    .{ //$
        0b00000,
        0b00100,
        0b01111,
        0b10100,
        0b01110,
        0b00101,
        0b11110,
        0b00100,
    },
    .{ //%
        0b00000,
        0b11000,
        0b11001,
        0b00010,
        0b00100,
        0b01000,
        0b10011,
        0b00011,
    },
    .{ //&
        0b00000,
        0b01000,
        0b10100,
        0b10100,
        0b01000,
        0b10101,
        0b10010,
        0b01101,
    },
    .{ //'
        0b00000,
        0b00100,
        0b00100,
        0b00100,
        0b00000,
        0b00000,
        0b00000,
        0b00000,
    },
    .{ //(
        0b00000,
        0b00100,
        0b01000,
        0b10000,
        0b10000,
        0b10000,
        0b01000,
        0b00100,
    },
    .{ //)
        0b00000,
        0b00100,
        0b00010,
        0b00001,
        0b00001,
        0b00001,
        0b00010,
        0b00100,
    },
    .{ //*
        0b00000,
        0b00100,
        0b10101,
        0b01110,
        0b00100,
        0b01110,
        0b10101,
        0b00100,
    },
    .{ //+
        0b00000,
        0b00000,
        0b00100,
        0b00100,
        0b11111,
        0b00100,
        0b00100,
        0b00000,
    },
    .{ //,
        0b00000,
        0b00000,
        0b00000,
        0b00000,
        0b00000,
        0b00100,
        0b00100,
        0b01000,
    },
    .{ //-
        0b00000,
        0b00000,
        0b00000,
        0b00000,
        0b11111,
        0b00000,
        0b00000,
        0b00000,
    },
    .{ //.
        0b00000,
        0b00000,
        0b00000,
        0b00000,
        0b00000,
        0b00000,
        0b00000,
        0b00100,
    },
    .{ // /
        0b00000,
        0b00000,
        0b00001,
        0b00010,
        0b00100,
        0b01000,
        0b10000,
        0b00000,
    },
    .{ //0
        0b00000,
        0b01110,
        0b10001,
        0b10011,
        0b10101,
        0b11001,
        0b10001,
        0b01110,
    },
    .{ //1
        0b00000,
        0b00100,
        0b01100,
        0b00100,
        0b00100,
        0b00100,
        0b00100,
        0b01110,
    },
    .{ //2
        0b00000,
        0b01110,
        0b10001,
        0b00001,
        0b00110,
        0b01000,
        0b10000,
        0b11111,
    },
    .{ //3
        0b00000,
        0b11111,
        0b00001,
        0b00010,
        0b00110,
        0b00001,
        0b10001,
        0b01110,
    },
    .{ //4
        0b00000,
        0b00010,
        0b00110,
        0b01010,
        0b10010,
        0b11111,
        0b00010,
        0b00010,
    },
    .{ //5
        0b00000,
        0b11111,
        0b10000,
        0b11110,
        0b00001,
        0b00001,
        0b10001,
        0b01110,
    },
    .{ //6
        0b00000,
        0b00111,
        0b01000,
        0b10000,
        0b11110,
        0b10001,
        0b10001,
        0b01110,
    },
    .{ //7
        0b00000,
        0b11111,
        0b00001,
        0b00010,
        0b00100,
        0b01000,
        0b01000,
        0b01000,
    },
    .{ //8
        0b00000,
        0b01110,
        0b10001,
        0b10001,
        0b01110,
        0b10001,
        0b10001,
        0b01110,
    },
    .{ //9
        0b00000,
        0b01110,
        0b10001,
        0b10001,
        0b01111,
        0b00001,
        0b00010,
        0b11100,
    },
    .{ //:
        0b00000,
        0b00000,
        0b00000,
        0b00100,
        0b00000,
        0b00100,
        0b00000,
        0b00000,
    },
    .{ //;
        0b00000,
        0b00000,
        0b00000,
        0b00100,
        0b00000,
        0b00100,
        0b00100,
        0b01000,
    },
    .{ //<
        0b00000,
        0b00010,
        0b00100,
        0b01000,
        0b10000,
        0b01000,
        0b00100,
        0b00010,
    },
    .{ //=
        0b00000,
        0b00000,
        0b00000,
        0b11111,
        0b00000,
        0b11111,
        0b00000,
        0b00000,
    },
    .{ //>
        0b00000,
        0b01000,
        0b00100,
        0b00010,
        0b00001,
        0b00010,
        0b00100,
        0b01000,
    },
    .{ //?
        0b00000,
        0b01110,
        0b10001,
        0b00010,
        0b00100,
        0b00100,
        0b00000,
        0b00100,
    },
    .{ //@
        0b00000,
        0b01110,
        0b10001,
        0b10101,
        0b10111,
        0b10110,
        0b10000,
        0b01111,
    },
    .{ //A
        0b00000,
        0b00100,
        0b01010,
        0b10001,
        0b10001,
        0b11111,
        0b10001,
        0b10001,
    },
    .{ //B
        0b00000,
        0b11110,
        0b10001,
        0b10001,
        0b11110,
        0b10001,
        0b10001,
        0b11110,
    },
    .{ //C
        0b00000,
        0b01110,
        0b10001,
        0b10000,
        0b10000,
        0b10000,
        0b10001,
        0b01110,
    },
    .{ //D
        0b00000,
        0b11110,
        0b10001,
        0b10001,
        0b10001,
        0b10001,
        0b10001,
        0b11110,
    },
    .{ //E
        0b00000,
        0b11111,
        0b10000,
        0b10000,
        0b11110,
        0b10000,
        0b10000,
        0b11111,
    },
    .{ //F
        0b00000,
        0b11111,
        0b10000,
        0b10000,
        0b11110,
        0b10000,
        0b10000,
        0b10000,
    },
    .{ //G
        0b00000,
        0b01111,
        0b10000,
        0b10000,
        0b10000,
        0b10011,
        0b10001,
        0b01111,
    },
    .{ //H
        0b00000,
        0b10001,
        0b10001,
        0b10001,
        0b11111,
        0b10001,
        0b10001,
        0b10001,
    },
    .{ //I
        0b00000,
        0b01110,
        0b00100,
        0b00100,
        0b00100,
        0b00100,
        0b00100,
        0b01110,
    },
    .{ //J
        0b00000,
        0b00001,
        0b00001,
        0b00001,
        0b00001,
        0b00001,
        0b10001,
        0b01110,
    },
    .{ //K
        0b00000,
        0b10001,
        0b10010,
        0b10100,
        0b11000,
        0b10100,
        0b10010,
        0b10001,
    },
    .{ //L
        0b00000,
        0b10000,
        0b10000,
        0b10000,
        0b10000,
        0b10000,
        0b10000,
        0b11111,
    },
    .{ //M
        0b00000,
        0b10001,
        0b11011,
        0b10101,
        0b10101,
        0b10001,
        0b10001,
        0b10001,
    },
    .{ //M
        0b00000,
        0b10001,
        0b10001,
        0b11001,
        0b10101,
        0b10011,
        0b10001,
        0b10001,
    },
    .{ //O
        0b00000,
        0b01110,
        0b10001,
        0b10001,
        0b10001,
        0b10001,
        0b10001,
        0b01110,
    },
    .{ //P
        0b00000,
        0b11110,
        0b10001,
        0b10001,
        0b11110,
        0b10000,
        0b10000,
        0b10000,
    },
    .{ //Q
        0b00000,
        0b01110,
        0b10001,
        0b10001,
        0b10001,
        0b10101,
        0b10010,
        0b01101,
    },
    .{ //R
        0b00000,
        0b11110,
        0b10001,
        0b10001,
        0b11110,
        0b10100,
        0b10010,
        0b10001,
    },
    .{ //S
        0b00000,
        0b01110,
        0b10001,
        0b10000,
        0b01110,
        0b00001,
        0b10001,
        0b01110,
    },
    .{ //T
        0b00000,
        0b11111,
        0b00100,
        0b00100,
        0b00100,
        0b00100,
        0b00100,
        0b00100,
    },
    .{ //U
        0b00000,
        0b10001,
        0b10001,
        0b10001,
        0b10001,
        0b10001,
        0b10001,
        0b01110,
    },
    .{ //V
        0b00000,
        0b10001,
        0b10001,
        0b10001,
        0b10001,
        0b10001,
        0b01010,
        0b00100,
    },
    .{ //W
        0b00000,
        0b10001,
        0b10001,
        0b10001,
        0b10101,
        0b10101,
        0b11011,
        0b10001,
    },
    .{ //X
        0b00000,
        0b10001,
        0b10001,
        0b01010,
        0b00100,
        0b01010,
        0b10001,
        0b10001,
    },
    .{ //Y
        0b00000,
        0b10001,
        0b10001,
        0b01010,
        0b00100,
        0b00100,
        0b00100,
        0b00100,
    },
    .{ //Z
        0b00000,
        0b11111,
        0b00001,
        0b00010,
        0b00100,
        0b01000,
        0b10000,
        0b11111,
    },
    .{ //[
        0b00000,
        0b11111,
        0b11000,
        0b11000,
        0b11000,
        0b11000,
        0b11000,
        0b11111,
    },
    .{ //\
        0b00000,
        0b00000,
        0b10000,
        0b01000,
        0b00100,
        0b00010,
        0b00001,
        0b00000,
    },
    .{ //]
        0b00000,
        0b11111,
        0b00011,
        0b00011,
        0b00011,
        0b00011,
        0b00011,
        0b11111,
    },
    .{ //^
        0b00000,
        0b00000,
        0b00000,
        0b00100,
        0b01010,
        0b10001,
        0b00000,
        0b00000,
    },
    .{ //_
        0b00000,
        0b00000,
        0b00000,
        0b00000,
        0b00000,
        0b00000,
        0b00000,
        0b11111,
    },
};

// const std = @import("std");
// test {
//     const at_bitmap = CHARACTERS[0];
//     const stdout = std.io.getStdOut().writer();
//     for (0..CharacterBitmap.HEIGHT) |y| {
//         for (0..CharacterBitmap.WIDTH) |x| {
//             if (at_bitmap.pixels[y * CharacterBitmap.WIDTH + x].data != 0) {
//                 try stdout.print("*", .{});
//             } else {
//                 try stdout.print(" ", .{});
//             }
//         }
//         try stdout.print("\n", .{});
//     }
// }

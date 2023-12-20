//Copyright Daniel Bokser 2023
//See LICENSE file for permissible source code usage

//This file is meant to be the main source file for the wozmon64 module imported by programs
const toolbox = @import("toolbox");

pub const MEMORY_PAGE_SIZE = toolbox.mb(2);

pub const SystemAPI = struct {
    register_key_events_queue: *const fn (key_events: *KeyEvents) callconv(.C) void,
};

const W64_API_ADDRESS_BASE = 0x240_0000;
pub const DEFAULT_PROGRAM_LOAD_ADDRESS = toolbox.align_up(W64_API_ADDRESS_BASE + 8, MEMORY_PAGE_SIZE);

////**** Screen/Frame buffer definitions ****////
pub const FRAME_BUFFER_VIRTUAL_ADDRESS = 0x20_0000;
pub const FRAME_BUFFER_PTR: [*]Pixel = @ptrFromInt(FRAME_BUFFER_VIRTUAL_ADDRESS);

const SCREEN_API_BEGIN = W64_API_ADDRESS_BASE;
pub const SCREEN_PIXEL_WIDTH_ADDRESS = SCREEN_API_BEGIN;
pub const SCREEN_PIXEL_HEIGHT_ADDRESS = SCREEN_PIXEL_WIDTH_ADDRESS + 8;
pub const FRAME_BUFFER_SIZE_ADDRESS = SCREEN_PIXEL_HEIGHT_ADDRESS + 8;
pub const FRAME_BUFFER_STRIDE_ADDRESS = FRAME_BUFFER_SIZE_ADDRESS + 8;
const SCREEN_API_END = FRAME_BUFFER_STRIDE_ADDRESS;

pub const SCREEN_PIXEL_WIDTH_PTR: *const u64 = @ptrFromInt(SCREEN_PIXEL_WIDTH_ADDRESS);
pub const SCREEN_PIXEL_HEIGHT_PTR: *const u64 = @ptrFromInt(SCREEN_PIXEL_HEIGHT_ADDRESS);
pub const FRAME_BUFFER_SIZE_PTR: *const u64 = @ptrFromInt(FRAME_BUFFER_SIZE_ADDRESS);
pub const FRAME_BUFFER_STRIDE_PTR: *const u64 = @ptrFromInt(FRAME_BUFFER_STRIDE_ADDRESS);

pub const Pixel = packed union {
    colors: packed struct(u32) {
        b: u8,
        g: u8,
        r: u8,
        reserved: u8 = 0,
    },
    data: u32,
};

////**** Input definitions ****////

const INPUT_API_BEGIN = SCREEN_API_END + 8;
pub const REGISTER_KEY_EVENT_QUEUE_API_ADDRESS = INPUT_API_BEGIN;
const INPUT_API_END = REGISTER_KEY_EVENT_QUEUE_API_ADDRESS;

pub const KeyEventQueue = toolbox.SingleProducerMultiConsumerRingQueue(ScanCode);

pub const KeyEvents = struct {
    modifier_key_pressed_events: KeyEventQueue,
    modifier_key_released_events: KeyEventQueue,
    key_pressed_events: KeyEventQueue,
    key_released_events: KeyEventQueue,

    pub fn init(arena: *toolbox.Arena) KeyEvents {
        const keys_pressed = KeyEventQueue.init(64, arena);
        const keys_released = KeyEventQueue.init(64, arena);
        const modifier_keys_pressed = KeyEventQueue.init(16, arena);
        const modifier_keys_released = KeyEventQueue.init(16, arena);

        return .{
            .key_pressed_events = keys_pressed,
            .key_released_events = keys_released,
            .modifier_key_pressed_events = modifier_keys_pressed,
            .modifier_key_released_events = modifier_keys_released,
        };
    }
};

pub const ScanCode = enum {
    Unknown,
    A,
    B,
    C,
    D,
    E,
    F,
    G,
    H,
    I,
    J,
    K,
    L,
    M,
    N,
    O,
    P,
    Q,
    R,
    S,
    T,
    U,
    V,
    W,
    X,
    Y,
    Z,

    Zero,
    One,
    Two,
    Three,
    Four,
    Five,
    Six,
    Seven,
    Eight,
    Nine,

    CapsLock,
    ScrollLock,
    NumLock,
    LeftShift,
    LeftCtrl,
    LeftAlt,
    LeftFlag,
    RightShift,
    RightCtrl,
    RightAlt,
    RightFlag,
    Pause,
    ContextMenu,

    Backspace,
    Escape,
    Insert,
    Home,
    PageUp,
    Delete,
    End,
    PageDown,
    UpArrow,
    LeftArrow,
    DownArrow,
    RightArrow,

    Space,
    Tab,
    Enter,

    Slash,
    Backslash,
    LeftBracket,
    RightBracket,
    Equals,
    Backtick,
    Hyphen,
    Semicolon,
    Quote,
    Comma,
    Period,

    NumDivide,
    NumMultiply,
    NumSubtract,
    NumAdd,
    NumEnter,
    NumPoint,
    Num0,
    Num1,
    Num2,
    Num3,
    Num4,
    Num5,
    Num6,
    Num7,
    Num8,
    Num9,

    PrintScreen,
    PrintScreen1,
    PrintScreen2,

    F1,
    F2,
    F3,
    F4,
    F5,
    F6,
    F7,
    F8,
    F9,
    F10,
    F11,
    F12,
};
pub fn scancode_to_ascii_shifted(scancode: ScanCode) u8 {
    return switch (scancode) {
        .Zero => ')',
        .One => '!',
        .Two => '@',
        .Three => '#',
        .Four => '$',
        .Five => '%',
        .Six => '^',
        .Seven => '&',
        .Eight => '*',
        .Nine => '(',

        .Slash => '?',
        .Backslash => '|',
        .LeftBracket => '{',
        .RightBracket => '}',
        .Equals => '+',
        .Backtick => '~',
        .Hyphen => '_',
        .Semicolon => ':',
        .Quote => '"',
        .Comma => '<',
        .Period => '>',

        else => scancode_to_ascii(scancode),
    };
}

pub fn scancode_to_ascii(scancode: ScanCode) u8 {
    return switch (scancode) {
        .A => 'A',
        .B => 'B',
        .C => 'C',
        .D => 'D',
        .E => 'E',
        .F => 'F',
        .G => 'G',
        .H => 'H',
        .I => 'I',
        .J => 'J',
        .K => 'K',
        .L => 'L',
        .M => 'M',
        .N => 'N',
        .O => 'O',
        .P => 'P',
        .Q => 'Q',
        .R => 'R',
        .S => 'S',
        .T => 'T',
        .U => 'U',
        .V => 'V',
        .W => 'W',
        .X => 'X',
        .Y => 'Y',
        .Z => 'Z',

        .Zero => '0',
        .One => '1',
        .Two => '2',
        .Three => '3',
        .Four => '4',
        .Five => '5',
        .Six => '6',
        .Seven => '7',
        .Eight => '8',
        .Nine => '9',

        .Space => ' ',
        .Enter => '\n',

        .Slash => '/',
        .Backslash => '\\',
        .LeftBracket => '[',
        .RightBracket => ']',
        .Equals => '=',
        .Backtick => '`',
        .Hyphen => '-',
        .Semicolon => ';',
        .Quote => '\'',
        .Comma => ',',
        .Period => '.',

        else => '?',
    };
}

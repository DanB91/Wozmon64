const toolbox = @import("toolbox");
const std = @import("std");

pub const ParseResult = union(enum) {
    Command: Command,
    HexNumberTooBig: struct {
        start: usize,
        end: usize,
    },
    InvalidToken: u8,
    UnexpectedToken: Token,
};

pub const Command = union(enum) {
    None,
    Read: struct {
        from: ?u64 = null,
        to: ?u64 = null,
        number_of_bytes: ?u64 = null,
    },
    Write: struct {
        start: u64,
        data: []const u8,
    },
    Execute: struct {
        start: u64,
    },
};

const TokenType = enum {
    Start,
    HexNumber,
    Dot,
    Colon,
    ForwardSlash,
    RunSuffix,
    End,
};

const Token = struct {
    start: usize = 0,
    end: usize = 0,
    payload: Payload,

    const Payload = union(TokenType) {
        Start: void,
        HexNumber: struct {
            value: u64,
            number_of_bytes: usize,
        },
        Dot: void,
        Colon: void,
        ForwardSlash: void,
        RunSuffix: void,
        End: void,
    };
};

const ParseState = struct {
    iterator: toolbox.RandomRemovalLinkedList(Token).Iterator,
    current_token: Token = .{ .payload = .Start },

    pub fn next(self: *ParseState) void {
        if (self.iterator.next_value()) |token| {
            self.current_token = token;
        } else {
            self.current_token = .{ .payload = .End };
        }
    }
    pub fn accept(self: *ParseState, comptime token_type: TokenType) ?Token {
        if (self.current_token.payload == token_type) {
            const ret = self.current_token;
            self.next();
            return ret;
        }
        return null;
    }
};

pub fn parse_command(command_buffer: []const u8, arena: *toolbox.Arena) ParseResult {
    if (command_buffer.len == 0) {
        return .{ .Command = .None };
    }

    var tokens = toolbox.RandomRemovalLinkedList(Token).init(arena);
    var i: usize = 0;

    //tokenize
    {
        while (i < command_buffer.len) {
            var char = command_buffer[i];

            if (is_hex_digit(char)) {
                var number: u64 = 0;
                var number_of_digits: usize = 0;
                var digit = command_buffer[i];
                const start = i;
                while (i < command_buffer.len) : (i += 1) {
                    digit = command_buffer[i];
                    if (!is_hex_digit(digit)) {
                        if (digit == '_') {
                            continue;
                        }
                        break;
                    }
                    number_of_digits += 1;
                    if (number_of_digits > 16) {
                        return .{ .HexNumberTooBig = .{ .start = start, .end = i } };
                    }
                    number <<= 4;
                    const nibble = switch (digit) {
                        '0'...'9' => digit - '0',
                        'A'...'F' => (digit - 'A') + 0xA,
                        else => unreachable,
                    };
                    number |= nibble;
                }
                const number_of_bytes: usize = switch (number) {
                    0...0xFF => 1,
                    0x1_00...0xFF_FF => 2,
                    0x1_00_00...0xFF_FF_FF => 3,
                    0x1_00_00_00...0xFF_FF_FF_FF => 4,
                    0x1_00_00_00_00...0xFF_FF_FF_FF_FF => 5,
                    0x1_00_00_00_00_00...0xFF_FF_FF_FF_FF_FF => 6,
                    0x1_00_00_00_00_00_00...0xFF_FF_FF_FF_FF_FF_FF => 7,
                    else => 8,
                };

                _ = tokens.append(
                    .{
                        .start = start,
                        .end = i,
                        .payload = .{
                            .HexNumber = .{
                                .value = number,
                                .number_of_bytes = number_of_bytes,
                            },
                        },
                    },
                );
            } else if (char == '.') {
                _ = tokens.append(.{ .start = i, .end = i + 1, .payload = .Dot });
                i += 1;
            } else if (char == ':') {
                _ = tokens.append(.{ .start = i, .end = i + 1, .payload = .Colon });
                i += 1;
            } else if (char == '/') {
                _ = tokens.append(.{ .start = i, .end = i + 1, .payload = .ForwardSlash });
                i += 1;
            } else if (char == ' ') {
                while (i < command_buffer.len and command_buffer[i] == ' ') : (i += 1) {}
            } else if (char == 'R') {
                _ = tokens.append(.{ .start = i, .end = i + 1, .payload = .RunSuffix });
                i += 1;
            } else {
                return .{ .InvalidToken = char };
            }
        }
    }

    //parse
    {
        var it = tokens.iterator();
        var parser = ParseState{ .iterator = it };
        if (parser.accept(.Start) == null) {
            unreachable;
        }

        if (parser.accept(.End)) |_| {
            return .{ .Command = .None };
        }

        const from_address = b: {
            if (parser.accept(.HexNumber)) |token| {
                break :b token.payload.HexNumber.value;
            }
            break :b null;
        };

        if (from_address) |address| {
            //execute
            if (parser.accept(.RunSuffix)) |_| {
                if (parser.accept(.End)) |_| {
                    return .{ .Command = .{ .Execute = .{ .start = address } } };
                }
                return .{ .UnexpectedToken = parser.current_token };
            }

            //write
            if (parser.accept(.Colon)) |_| {
                var data = toolbox.DynamicArray(u8).init(arena, 16);
                while (parser.accept(.HexNumber)) |token| {
                    const payload = token.payload.HexNumber;
                    var number = payload.value;
                    for (0..payload.number_of_bytes) |_| {
                        data.append(@truncate(number));
                        number >>= 8;
                    }
                }
                if (parser.accept(.End)) |_| {
                    return .{ .Command = .{ .Write = .{
                        .start = address,
                        .data = data.items(),
                    } } };
                }

                return .{ .UnexpectedToken = parser.current_token };
            }
        }

        //read
        if (parser.accept(.Dot)) |dot_token| {
            // e.g "FFFF_FFFFF.1_0000_0005"
            if (parser.accept(.HexNumber)) |token| {
                if (parser.accept(.End)) |_| {
                    return .{ .Command = .{ .Read = .{
                        .from = from_address,
                        .to = token.payload.HexNumber.value,
                    } } };
                }
            }
            return .{ .UnexpectedToken = dot_token };
        } else if (parser.accept(.ForwardSlash)) |slash_token| {
            //e.g. "FFFF_FFFFF/16"
            if (parser.accept(.HexNumber)) |token| {
                if (parser.accept(.End)) |_| {
                    return .{ .Command = .{ .Read = .{
                        .from = from_address,
                        .number_of_bytes = token.payload.HexNumber.value,
                    } } };
                }
            }
            return .{ .UnexpectedToken = slash_token };
        } else if (parser.accept(.End)) |_| {
            //e.g. "1_0000_0005"
            return .{ .Command = .{ .Read = .{
                .from = from_address,
            } } };
        } else {
            return .{ .UnexpectedToken = parser.current_token };
        }

        //if this case is reached, we just have a dot
        // toolbox.assert(
        //     from_address != null or to_address != null,
        //     "One of the from_address or to_address must not be null!",
        //     .{},
        // );

        return .{ .UnexpectedToken = parser.current_token };
    }
}

fn is_hex_digit(char: u8) bool {
    return switch (char) {
        '0'...'9', 'A'...'F' => true,
        else => false,
    };
}

test "Parse Read Range" {
    const command = "FF00.FFFF";
    const scratch_arena = toolbox.Arena.init(toolbox.kb(32));
    const parse_result = parse_command(command, scratch_arena);
    try std.testing.expectEqual(ParseResult{
        .Command = .{
            .Read = .{
                .from = 0xFF00,
                .to = 0xFFFF,
            },
        },
    }, parse_result);
}

test "Parse Read Implicit" {
    const command = ".FFFF";
    const scratch_arena = toolbox.Arena.init(toolbox.kb(32));
    const parse_result = parse_command(command, scratch_arena);
    try std.testing.expectEqual(ParseResult{
        .Command = .{
            .Read = .{
                .from = null,
                .to = 0xFFFF,
            },
        },
    }, parse_result);
}
test "Parse Read One Byte" {
    const command = "FFFF_1234";
    const scratch_arena = toolbox.Arena.init(toolbox.kb(32));
    const parse_result = parse_command(command, scratch_arena);
    try std.testing.expectEqual(ParseResult{
        .Command = .{
            .Read = .{
                .from = 0xFFFF_1234,
                .to = null,
            },
        },
    }, parse_result);
}

test "Parse Run" {
    const command = "      FFFF______FFFF R   ";
    const scratch_arena = toolbox.Arena.init(toolbox.kb(32));
    const parse_result = parse_command(command, scratch_arena);
    try std.testing.expectEqual(ParseResult{
        .Command = .{
            .Execute = .{ .start = 0xFFFF_FFFF },
        },
    }, parse_result);
}

test "Parse Write" {
    const command = "      FFFF______FFFF: FF 49939 4949   ";
    const scratch_arena = toolbox.Arena.init(toolbox.kb(32));
    const parse_result = parse_command(command, scratch_arena);
    try std.testing.expectEqualDeep(ParseResult{
        .Command = .{
            .Write = .{
                .start = 0xFFFF_FFFF,
                .data = &[_]u8{ 0xFF, 0x39, 0x99, 0x4, 0x49, 0x49 },
            },
        },
    }, parse_result);
}

test "Parse Blanks" {
    const command = "                           ";
    const scratch_arena = toolbox.Arena.init(toolbox.kb(32));
    const parse_result = parse_command(command, scratch_arena);
    try std.testing.expectEqual(ParseResult{
        .Command = .None,
    }, parse_result);
}

test "Parse Garbage" {
    const command = "oifjdaiofjadoidja                     ";
    const scratch_arena = toolbox.Arena.init(toolbox.kb(32));
    const parse_result = parse_command(command, scratch_arena);
    try std.testing.expectEqual(ParseResult{
        .InvalidToken = 'o',
    }, parse_result);
}

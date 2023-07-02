const uefi = @import("std").os.uefi;
const Guid = uefi.Guid;
const Status = uefi.Status;

pub const TimestampProtocol = extern struct {
    get_proprties: *const fn (properties: *TimestampProperties) callconv(.C) Status,
    get: *const fn () callconv(.C) u64,

    pub const guid align(8) = Guid{
        .time_low = 0xafbfde41,
        .time_mid = 0x2e6e,
        .time_high_and_version = 0x4262,
        .clock_seq_high_and_reserved = 0xba,
        .clock_seq_low = 0x65,
        .node = [_]u8{ 0x62, 0xb9, 0x23, 0x6e, 0x54, 0x95 },
    };
};

pub const TimestampProperties = extern struct {
    frequency: u64,
    end_value: u64,
};

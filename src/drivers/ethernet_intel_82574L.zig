const pcie = @import("pcie.zig");
const w64 = @import("../wozmon64_kernel.zig");
const kernel_memory = @import("../kernel_memory.zig");
const kernel = @import("../kernel.zig");

const echo_line = kernel.echo_line;

pub const VENDOR_ID = 0x8086;
pub const DEVICE_ID = 0x10D3;
pub const CHECKSUM = 0xBABA;

//AKA "EERD"
const EEPROMReadRegister = packed struct(u32) {
    start: bool,
    done: bool,
    addr: u14,
    data: u16,

    pub const BYTE_OFFSET = 0x14;
};

const InterruptMaskClearRegister = packed struct(u32) {
    //this can be broken up, into different fields.  but lumping them all together for now
    all_masks: u25,
    must_be_zero: u7 = 0,

    pub const BYTE_OFFSET = 0xD8;
};

pub fn init(pcie_device: pcie.Device) void {
    var pcie_device_header = pcie_device.end_point_device_header();
    {
        var command = pcie_device_header.command;
        command.io_mapped = false;
        command.memory_mapped = true;
        command.bus_master_dma_enabled = true;
        command.interrupt_disabled = false;
        pcie_device_header.command = command;
    }

    //TODO: reset hardware before doing anything else
    const bar0 = pcie_device.base_address_registers[0].?;

    //initialize device
    {
        //disable interrupts
        write_register(bar0, InterruptMaskClearRegister{
            .all_masks = 0x1FFFFFF,
        });
        //TODO: we are supposed to do a global reset here.
        //I can't figure out how to do this, since I can't figure out how to strobe the PE_RST_N pin.
        //let's just assume its reset and in a default state for now

        //TODO: once we global reset, we re-disable interrupts

    }

    var checksum: u16 = 0;
    for (0..0x40) |nvm_address| {
        const data = read_nvm(@intCast(nvm_address), bar0);
        checksum +%= data;
    }

    if (checksum != CHECKSUM) {
        echo_line("Ethernet checksum is incorrect! Expected: {X}, but was {X}", .{ CHECKSUM, checksum });
        return;
    }

    var mac_address = [_]u8{0} ** 6;
    var cursor: usize = 0;
    for (0..mac_address.len / 2) |i| {
        const data = read_nvm(@intCast(i), bar0);
        mac_address[cursor] = @intCast(data & 0xFF);
        cursor += 1;
        mac_address[cursor] = @intCast(data >> 8);
        cursor += 1;
    }
    echo_line("Ethernet MAC address: {X}", .{mac_address});

    const version = read_nvm(5, bar0);
    echo_line("Ethernet version: {X}", .{version});
}

fn read_nvm(nvm_address: u14, bar: pcie.BaseAddressRegisterData) u16 {
    var eerd_value = EEPROMReadRegister{
        .start = true,
        .done = false,
        .addr = nvm_address,
        .data = 0,
    };
    write_register(bar, eerd_value);
    for (0..10000) |_| {
        eerd_value = read_register(EEPROMReadRegister, bar);
        if (eerd_value.done) {
            return eerd_value.data;
        }
    }
    return 0;
}
fn read_register(comptime Type: type, bar: pcie.BaseAddressRegisterData) Type {
    const register_ptr = bar_to_register(Type, bar);
    return register_ptr.*;
}

fn write_register(bar: pcie.BaseAddressRegisterData, value: anytype) void {
    const register_ptr = bar_to_register(@TypeOf(value), bar);
    register_ptr.* = value;
}
fn bar_to_register(comptime Register: type, bar: pcie.BaseAddressRegisterData) *volatile Register {
    return @ptrCast(
        @alignCast(bar[Register.BYTE_OFFSET .. Register.BYTE_OFFSET + @sizeOf(Register)].ptr),
    );
}

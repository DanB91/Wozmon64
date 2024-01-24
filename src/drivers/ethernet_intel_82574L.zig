const pcie = @import("pcie.zig");
const w64 = @import("../wozmon64_kernel.zig");
const kernel_memory = @import("../kernel_memory.zig");
const kernel = @import("../kernel.zig");

const boot_log_println = kernel.boot_log_println;

pub const VENDOR_ID = 0x8086;
pub const DEVICE_ID = 0x10D3;

//AKA "EERD"
const EEPROMReadRegister = packed struct(u32) {
    start: bool,
    done: bool,
    addr: u14,
    data: u16,

    pub const BYTE_OFFSET = 0x14;
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

    var checksum: u16 = 0;
    for (0..0x40) |nvm_address| {
        const data = read_nvm(@intCast(nvm_address), bar0) catch |e| {
            boot_log_println("Error reading NVM: {}", .{e});
            return;
        };
        checksum +%= data;
    }
    boot_log_println("Ethernet check sum: {X}", .{checksum});

    for (0..3) |i| {
        const data = read_nvm(@intCast(i), bar0) catch |e| {
            boot_log_println("Error reading NVM: {}", .{e});
            return;
        };
        boot_log_println("MAC address bytes: {X}, {X}", .{ data & 0xFF, data >> 8 });
    }
}

fn read_nvm(nvm_address: u14, bar: pcie.BaseAddressRegisterData) !u16 {
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
    return error.NvmReadTimedOut;
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

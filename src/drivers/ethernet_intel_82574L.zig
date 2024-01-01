const pcie = @import("pcie.zig");
const w64 = @import("../wozmon64_kernel.zig");
const kernel_memory = @import("../kernel_memory.zig");

const println_serial = w64.println_serial;

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

pub fn init(pcie_device: *const pcie.Device) !void {
    var pcie_device_header = pcie_device.header.EndPointDevice;
    {
        var command = pcie_device_header.command;
        command.io_mapped = false;
        command.memory_mapped = true;
        command.bus_master_dma_enabled = true;
        command.interrupt_disabled = true;
        pcie_device_header.command = command;
    }
    const physical_bar0 = pcie_device_header.effective_bar0();
    const mmio_size = pcie_device_header.mmio_size();
    const number_of_mmio_pages_to_map = mmio_size / w64.MMIO_PAGE_SIZE;
    println_serial("Ethernet physical bar0: {X}, MMIO size: {} bytes, pages: {}", .{
        physical_bar0,
        mmio_size,
        number_of_mmio_pages_to_map,
    });
    const bar0 = kernel_memory.physical_to_virtual(physical_bar0) catch b: {
        break :b kernel_memory.map_mmio_physical_address(
            physical_bar0,
            number_of_mmio_pages_to_map,
        );
    };

    //TODO: reset hardware before doing anything else

    var checksum: u16 = 0;
    for (0..0x40) |nvm_address| {
        const read_result = read_nvm(@intCast(nvm_address), bar0);
        switch (read_result) {
            .Data => |data| {
                checksum +%= data;
            },
            .TimedOut => {
                println_serial("Timed out reading NVM", .{});
                return;
            },
        }
    }
    println_serial("Ethernet check sum: {X}", .{checksum});

    for (0..3) |i| {
        const data = read_nvm(@intCast(i), bar0) catch |e| {
            println_serial("Error reading NVM: {}", .{e});
            return;
        };
        println_serial("MAC address bytes: {X}, {X}", .{ data & 0xFF, data >> 8 });
    }
}

fn read_nvm(nvm_address: u14, bar0: u64) !u16 {
    var eerd_value = EEPROMReadRegister{
        .start = true,
        .done = false,
        .addr = nvm_address,
        .data = 0,
    };
    write_register(bar0, eerd_value);
    for (0..10000) |_| {
        eerd_value = read_register(EEPROMReadRegister, bar0);
        if (eerd_value.done) {
            return eerd_value.data;
        }
    }
    return error.NvmReadTimedOut;
}
fn read_register(comptime Type: type, bar0: u64) Type {
    const register_ptr: *volatile Type = @ptrFromInt(bar0 + Type.BYTE_OFFSET);
    return register_ptr.*;
}

fn write_register(bar0: u64, value: anytype) void {
    const Type = @TypeOf(value);
    const register_ptr: *volatile Type = @ptrFromInt(bar0 + Type.BYTE_OFFSET);
    register_ptr.* = value;
}

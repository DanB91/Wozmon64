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

const ControlRegister = packed struct(u32) {
    data: u32,

    pub const BYTE_OFFSET = 0;
};

const ReceiveControlRegister = packed struct(u32) {
    data: u32,

    pub const BYTE_OFFSET = 0x100;
};

const StatusRegister = packed struct(u32) {
    fd: bool, //Full Duplex
    lu: bool, //Link up
    reserved0: u2,
    txoff: bool, //Transmission paused
    reserved1: u1,
    speed: Speed,
    asdv: Speed, //Auto detected speed valuw
    phyra: bool, //PHY reset asserted.  If true, must perform reset of PHY (R/W)
    reserved2: u8,
    gio_master_enable_status: bool,
    reserved3: u12,

    const Speed = enum(u2) {
        TenMBs,
        OneHundredMBs,
        OneThousandMBs0,
        OneThousandMBs1,
    };
    pub const BYTE_OFFSET = 8;
};

const InterruptMaskClearRegister = packed struct(u32) {
    //this can be broken up, into different fields.  but lumping them all together for now
    all_masks: u25,
    must_be_zero: u7 = 0,

    pub const BYTE_OFFSET = 0xD8;
};

pub fn init(pcie_device: pcie.Device) bool {
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
        // The following sequence of commands is typically issued to the device by the software
        // device driver in order to initialize the 82574 to normal operation. The major
        // initialization steps are:
        // 1. Disable Interrupts - see Interrupts during initialization.
        write_register(bar0, InterruptMaskClearRegister{
            .all_masks = 0x1FFFFFF,
        });
        // 2. Issue Global Reset and perform General Configuration - see Global Reset and
        // General Configuration.
        //TODO: I can't figure out how to do this, since I can't figure out how to strobe the PE_RST_N pin.
        //let's just assume its reset and in a default state for now

        //TODO: once we global reset, we re-disable interrupts

        // 3. Setup the PHY and the link - see Link Setup Mechanisms and Control/Status Bit

        {
            const result = setup_phy_and_link(bar0);
            if (result.success) {
                echo_line("Ethernet link up with speed: {}", .{result.speed});
            } else {
                echo_line("Ethernet link not up as expected. Aborting...", .{});
                //TODO: logging
                return false;
            }
        }
        // 4. Initialize all statistical counters - see Initialization of Statistics.

        //TODO

        // 5. Initialize Receive - see Receive Initialization.
        _ = setup_receive(bar0);

        // 6. Initialize Transmit - see Transmit Initialization.
        // 7. Enable Interrupts - see Interrupts during initialization.

    }

    var checksum: u16 = 0;
    for (0..0x40) |nvm_address| {
        const data = read_nvm(@intCast(nvm_address), bar0);
        checksum +%= data;
    }

    if (checksum != CHECKSUM) {
        echo_line("Ethernet checksum is incorrect! Expected: {X}, but was {X}", .{ CHECKSUM, checksum });
        return false;
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

    return true;
}

const SetupPHYAndLinkResult = struct {
    success: bool = false,
    speed: StatusRegister.Speed = .TenMBs,
};
fn setup_phy_and_link(bar: pcie.BaseAddressRegisterData) SetupPHYAndLinkResult {
    // MAC settings automatically based on duplex and speed resolved by PHY.
    // (CTRL.FRCDPLX = 0b, CTRL.FRCSPD = 0b, CTRL.ASDE = 0b)
    // — CTRL.FD - Don't care; duplex setting is established from PHY's internal
    // indication to the MAC (FDX) after PHY has auto-negotiated a successful link-up.
    // — CTRL.SLU - Must be set to 1b by software to enable communications between
    // MAC and PHY.
    // — CTRL.RFCE - Must be set by software after reading flow control resolution from
    // PHY registers.
    // — CTRL.TFCE - Must be set by software after reading flow control resolution from
    // PHY registers.
    // — CTRL.SPEED - Don't care; speed setting is established from PHY's internal
    // indication to the MAC (SPD_IND) after PHY has auto-negotiated a successful
    // link-up.
    // — STATUS.FD - Reflects the actual duplex setting (FDX) negotiated by the PHY
    // and indicated to the MAC.
    // — STATUS.LU - Reflects link indication (LINK) from the PHY qualified with
    // CTRL.SLU (set to 1b).
    // — STATUS.SPEED - Reflects actual speed setting negotiated by the PHY and
    // indicated to the MAC (SPD_IND).

    //All the above should already be configured in QEMU, just check the status register
    const status = read_register(StatusRegister, bar);
    if (!status.lu) {
        return .{};
    }
    return .{
        .success = true,
        .speed = status.speed,
    };
}

const SetupReceiveResult = struct {
    success: bool = false,
};
fn setup_receive(bar: pcie.BaseAddressRegisterData) SetupReceiveResult {
    // Program the receive address register(s) per the station address. This can come from
    // the NVM or from any other means, for example, on some systems, this comes from the
    // system EEPROM not the NVM on a Network Interface Card (NIC).
    // Set up the Multicast Table Array (MTA) per software. This generally means zeroing all
    // entries initially and adding in entries as requested.

    //Multicast Table Array - MTA[127:0] (0x05200-0x053FC; RW)
    {
        const mta = @as([*]volatile u32, @ptrCast(@alignCast(bar.ptr)))[0x05200 / 4 .. 0x05400 / 4];
        @memset(mta, 0);
    }

    // Program the interrupt mask register to pass any interrupt that the software device
    // driver cares about. Suggested bits include RXT, RXO, RXDMT and LSC. There is no
    // reason to enable the transmit interrupts.

    //TODO

    // Program RCTL with appropriate values. If initializing it at this stage, it is best to leave
    // the receive logic disabled (EN = 0b) until the receive descriptor ring has been
    // initialized. If VLANs are not used, software should clear the VFE bit. Then there is no
    // need to initialize the VFTA array. Select the receive descriptor type. Note that if using
    // the header split RX descriptors, tail and head registers should be incremented by two
    // per descriptor.

    const rctl = read_register(ReceiveControlRegister, bar);
    echo_line("RCTL: {b}", .{rctl.data});

    //     To properly receive packets requires simply that the receiver is enabled. This should be
    // done only after all other setup is accomplished. If software uses the Receive Descriptor
    // Minimum Threshold Interrupt, that value should be set.
    // The following should be done once per receive queue:
    // • Allocate a region of memory for the receive descriptor list.
    // • Receive buffers of appropriate size should be allocated and pointers to these
    // buffers should be stored in the descriptor ring.
    // • Program the descriptor base address with the address of the region.
    // • Set the length register to the size of the descriptor ring.
    // • If needed, program the head and tail registers. Note: the head and tail pointers are
    // initialized (by hardware) to zero after a power-on or a software-initiated device
    // reset.
    // • The tail pointer should be set to point one descriptor beyond the end

    return .{ .success = true };
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

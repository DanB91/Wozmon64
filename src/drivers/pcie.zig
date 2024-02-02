const amd64 = @import("../amd64.zig");
const toolbox = @import("toolbox");
const w64 = @import("../wozmon64_kernel.zig");
const kernel_memory = @import("../kernel_memory.zig");
const kernel = @import("../kernel.zig");

const echo_line = kernel.echo_line;

pub const END_POINT_DEVICE_HEADER_TYPE = 0;
pub const BRIDGE_DEVICE_HEADER_TYPE = 1;
pub const HEADER_TYPE_BYTE_OFFSET = 0xE;
pub const MASS_STORAGE_CLASS_CODE = 0x1;
pub const NVME_SUBCLASS_CODE = 0x8;
pub const NETWORK_CONTROLLER_CLASS_CODE = 0x2;
pub const ETHERNET_CONTROLLER_SUBCLASS_CODE = 0;
pub const SERIAL_BUS_CLASS_CODE = 0xC;
pub const USB_SUBCLASS_CODE = 0x3;
pub const EHCI_PROGRAMING_INTERFACE = 0x20;
pub const XHCI_PROGRAMING_INTERFACE = 0x30;
pub const USB_DEVICE_PROGRAMING_INTERFACE = 0xFE;
pub const MSI_CAPABILITY_ID = 0x5;
pub const MSI_X_CAPABILITY_ID = 0x11;

pub const BaseAddressRegisterData = []volatile u8;

pub const Device = struct {
    device: u64,
    function: u64,
    bus: u64,
    header_type: DeviceHeaderType,
    header: *align(4096) volatile anyopaque,
    config_data: []volatile u8,
    base_address_registers: []?BaseAddressRegisterData,

    pub fn end_point_device_header(self: Device) *align(4096) volatile EndPointDeviceHeader {
        toolbox.assert(
            self.header_type == .EndPointDevice,
            "Wrong PCIe device type header. Expected {}, but was {}",
            .{
                DeviceHeaderType.EndPointDevice,
                self.header_type,
            },
        );
        return @ptrCast(self.header);
    }
    pub fn bridge_device_header(self: Device) *align(4096) volatile BridgeDeviceHeader {
        toolbox.assert(
            self.header_type == .BridgeDevice,
            "Wrong PCIe device type header. Expected {}, but was {}",
            .{
                DeviceHeaderType.BridgeDevice,
                self.header_type,
            },
        );
        return @ptrCast(self.header);
    }
    pub fn get_config_data(self: Device, comptime Data: type, byte_offset: usize) ?*volatile Data {
        comptime {
            toolbox.static_assert(@sizeOf(Data) % 4 == 0, "Wrong size for config data");
        }
        toolbox.assert(
            byte_offset < self.config_data.len,
            "Byte offset greater than config data len. " ++
                "Re-evaluate if this is a valid case. Byte offset: {}, Len: {}",
            .{ byte_offset, self.config_data.len },
        );
        if (byte_offset == 0) {
            return null;
        }
        return @ptrCast(
            @alignCast(
                self.config_data[byte_offset .. byte_offset + @sizeOf(Data)].ptr,
            ),
        );
    }
};

const MCFG = extern struct {
    xsdt: amd64.XSDT align(1),
    reserved: u64 align(1),

    fn config_space_descriptors(self: *const MCFG) []const ConfigSpaceDescriptor {
        const addr = @intFromPtr(self) + @sizeOf(MCFG);
        const num_descriptors = (self.xsdt.length - @sizeOf(MCFG)) / @sizeOf(ConfigSpaceDescriptor);
        return @as(
            [*]const ConfigSpaceDescriptor,
            @ptrFromInt(addr),
        )[0..num_descriptors];
    }
};
const ConfigSpaceDescriptor = extern struct {
    base_address: u64 align(1),
    pci_segment_group_number: u16 align(1),
    start_pci_bus_number: u8 align(1),
    end_pci_bus_number: u8 align(1),
    reserved: u32 align(1),
};

const DeviceHeaderType = enum {
    EndPointDevice,
    BridgeDevice,
};
pub const CapabilityHeader = packed struct(u32) {
    capability_id: u8,
    next_pointer: u8,
    reserved: u16,
};
pub const MSIXCapabilityHeader = packed struct(u32) {
    capability_id: u8 = 0,
    next_pointer: u8 = 0,
    message_control: MessageControl = .{},

    pub const MessageControl = packed struct(u16) {
        table_size: u11 = 0,
        reserved: u3 = 0,
        function_mask: u1 = 0,
        enable: bool = false,
    };
};

pub const MSICapabilityHeader = packed struct(u32) {
    capability_id: u8 = 0,
    next_pointer: u8 = 0,
    message_control: MessageControl = .{},

    pub const MessageControl = packed struct(u16) {
        enable: bool = false,
        multiple_message_capable: NumberOfVectors = .OneVector,
        multiple_message_enable: NumberOfVectors = .OneVector,
        is_64_bit_address_capable: bool = false,
        is_per_vector_masking_capable: bool = false,
        reserved: u7 = 0,

        const NumberOfVectors = enum(u3) {
            OneVector,
            TwoVectors,
            FourVectors,
            EightVectors,
            SixteenVectors,
            ThirtyTwoVectors,
            Reserved0,
            Reserved1,
        };
    };
};
//TODO: first we should check and log if there is MSI. we need to disable MSI
//TODO: We should re-work this API to only read/write 32-bit registers at a time
pub const MSIXCapabilityStructure = extern struct {
    header: MSIXCapabilityHeader align(4),
    table_offset: u32 align(4),
    pending_bit_array_offset: u32 align(4), // AKA "PBA".  Don't know what we will use this for

    pub const BIR_MASK = 7;

    pub fn table(self: MSIXCapabilityStructure, bar: BaseAddressRegisterData) []volatile MSIXTableEntry {
        const offset: usize = self.table_offset & ~@as(u32, BIR_MASK);
        const len = @as(usize, self.header.message_control.table_size) + 1;
        echo_line("BAR len: 0x{X}, Table offset: 0x{X}, PBA offset: 0x{X}, table byte len: 0x{X}", .{
            bar.len,
            offset,
            self.pending_bit_array_offset,
            len * @sizeOf(MSIXTableEntry),
        });
        const table_bytes = bar[offset .. offset + len * @sizeOf(MSIXTableEntry)];
        echo_line(
            "Table addr: 0x{X}, table len: {}",
            .{
                @intFromPtr(table_bytes.ptr),
                len,
            },
        );
        const table_ptr: [*]volatile MSIXTableEntry = @ptrCast(@alignCast(table_bytes.ptr));
        return table_ptr[0..len];
    }
};

//from https://cdrdv2.intel.com/v1/dl/getContent/671200
pub const MSIXAMD64MessageAddress = packed struct(u32) {
    reserved0: u2 = 0,
    //has to do with using logic processor groups. We don't care about this right now.
    destination_mode: u1 = 0,
    //this allows priority list of cores. if one core is servicing an interrupt can try another core.
    //don't care about this right now.
    redirection_hint: u1 = 0,
    reserved1: u8 = 0,
    destination_id: u8 = 0, //id of the core to interrupt
    address_prefix: u12 = 0xFEE, //fixed value.  do not change

    const DWORD_OFFSET = 0;
};

pub const MSIXAMD64MessageData = packed struct(u32) {
    vector: u8 = 0,

    //we really only care about external interrupts here
    delivery_mode: enum(u3) {
        Fixed = 0b000,
        LowestPriority = 0b001,
        SystemManagementInterrupt = 0b010, //SMI
        Reserved0 = 0b011,
        NonMaskableInterrupt = 0b100, //NMI
        Initialize = 0b101, //INIT
        Reserved1 = 0b110,
        ExternalInterrupt = 0b111,
    } = .Fixed, //.ExternalInterrupt,

    reserved0: u3 = 0,

    //only matters for level-triggered interrupts
    //ignored for edge-triggered interrupts
    level: enum(u1) {
        Deassert,
        Assert,
    } = .Deassert,

    trigger_mode: enum(u1) {
        Edge = 0,
        Level = 1,
    } = .Edge, //thinking we only care about Edge triggered

    reserved1: u16 = 0,

    const DWORD_OFFSET = 2;
};
pub const MSIXVectorControl = packed struct(u32) {
    disabled: bool = false, //the "mask" bit
    reserved: u31 = 0,

    const DWORD_OFFSET = 3;
};
pub const MSIXTableEntry = extern struct {
    data: [4]u32 align(4),
    // message_address: MSIXAMD64MessageAddress = .{},
    // unused_in_amd64: u32 = 0,
    // message_data: MSIXAMD64MessageData = .{},
    // vector_control: packed struct(u32) {
    //     disabled: bool = false, //the "mask" bit
    //     reserved: u31 = 0,
    // },

    pub fn read_register(self: *const volatile MSIXTableEntry, comptime T: type) T {
        return @bitCast(self.data[T.DWORD_OFFSET]);
    }
    pub fn write_register(self: *volatile MSIXTableEntry, value: anytype) void {
        const T = @TypeOf(value);
        self.data[T.DWORD_OFFSET] = @bitCast(value);
    }
};

// pub const MSIXTableEntry = extern struct {
//     message_address: MSIXAMD64MessageAddress align(4),
//     unused_in_amd64: u32 align(4) = 0,
//     message_data: MSIXAMD64MessageData align(4),
//     vector_control: packed struct(u32) {
//         disabled: bool, //the "mask" bit
//         reserved: u31 = 0,
//     } align(4),
// };
const DeviceStatusRegister = packed struct(u16) {
    reserved0: u3,
    interrupt_status: u1,
    has_capabilities_list: bool,
    is_66mhz_capable: bool,
    reserved1: u1,
    fast_back_to_back_capable: bool,
    master_data_parity_error: u1,
    devsel_timing: u2,
    signaled_target_abort: bool,
    received_target_abort: bool,
    received_master_abort: bool,
    signaled_system_error: u1,
    detected_parity_error: u1,
};
const DeviceCommandRegister = packed struct(u16) {
    io_mapped: bool,
    memory_mapped: bool,
    bus_master_dma_enabled: bool,
    special_cycles_enabled: bool,
    memory_write_and_invalidate_enabled: bool,
    vga_palette_snoop: bool,
    parity_error_response: u1,
    reserved: u1,
    serr_driver_enabled: bool,
    interrupt_disabled: bool,
    reserved1: u6,
};

pub const EndPointDeviceHeader = extern struct {
    vendor_id: u16 align(1),
    device_id: u16 align(1),
    command: DeviceCommandRegister align(1),
    status: DeviceStatusRegister align(1),
    revision_id: u8 align(1),
    programming_interface_byte: u8 align(1),
    subclass_code: u8 align(1),
    class_code: u8 align(1),
    cache_line_size: u8 align(1),
    latency_timer: u8 align(1),
    header_type: u8 align(1),
    built_in_self_test: u8 align(1),
    base_address_registers: [6]u32 align(1),
    cardbus_cs_pointer: u32 align(1),
    subsystem_vendor_id: u16 align(1),
    subsystem_id: u16 align(1),
    expansion_rom_base_address: u32 align(1),
    capabilities_pointer: u32 align(1),
    reserved: u32 align(1),
    interrupt_line: u8 align(1),
    interrupt_pin: u8 align(1),
    min_grant: u8 align(1),
    max_latency: u8 align(1),
};
pub const BridgeDeviceHeader = extern struct {
    vendor_id: u16 align(1),
    device_id: u16 align(1),
    command: DeviceCommandRegister align(1),
    status: DeviceStatusRegister align(1),
    revision_id: u8 align(1),
    programming_interface_byte: u8 align(1),
    subclass_code: u8 align(1),
    class_code: u8 align(1),
    cache_line_size: u8 align(1),
    latency_timer: u8 align(1),
    header_type: u8 align(1),
    built_in_self_test: u8 align(1),
    base_address_registers: [2]u32 align(1),
    primary_bus_number: u8 align(1),
    secondary_bus_number: u8 align(1),
    subordinate_bus_number: u8 align(1),
    secondary_latency_timer: u8 align(1),
    io_base: u8 align(1),
    io_limit: u8 align(1),
    secondary_status: u16 align(1),
    memory_base: u16 align(1),
    memory_limit: u16 align(1),
    prefetchable_base: u16 align(1),
    prefetchable_limit: u16 align(1),
    prefetchable_base_upper32: u32 align(1),
    prefetchable_limit_upper32: u32 align(1),
    io_base_upper16: u16 align(1),
    io_limit_upper16: u16 align(1),
    capabilities_pointer: u32 align(1),
    expansion_rom_base_address: u32 align(1),
    interrupt_line: u8 align(1),
    interrupt_pin: u8 align(1),
    bridge_control: u16 align(1),
};

comptime {
    toolbox.static_assert(@sizeOf(ConfigSpaceDescriptor) == 16, "Wrong size for ConfigSpaceDescriptor");
    toolbox.static_assert(@sizeOf(EndPointDeviceHeader) == 64, "Wrong size for EndPointDeviceHeader");
    toolbox.static_assert(@sizeOf(EndPointDeviceHeader) == @sizeOf(BridgeDeviceHeader), "Wrong size for BridgeDeviceHeader");
    toolbox.static_assert(@sizeOf(MSIXCapabilityStructure) == 12, "Wrong size of MSIXCapabilityStructure");
}

pub fn enumerate_devices(
    root_xsdt: *const amd64.XSDT,
    arena: *toolbox.Arena,
) []const Device {
    var ret = toolbox.DynamicArray(Device).init(arena, 32);
    const mcfg = amd64.find_acpi_table(root_xsdt, "MCFG", MCFG) catch
        toolbox.panic("Could not find MCFG table!", .{});

    const pci_descriptors = mcfg.config_space_descriptors();

    for (pci_descriptors) |pd| {
        var bus: u64 = 0;
        var max_bus_opt: ?u64 = null;
        bus_loop: while (true) : (bus += 1) {
            if (max_bus_opt) |max_bus| {
                if (bus >= max_bus) {
                    break;
                }
            }
            device_loop: for (0..32) |device_number| {
                function_loop: for (0..8) |function_number| {
                    const pci_request_paddr = pd.base_address +
                        ((bus - pd.start_pci_bus_number) << 20 | device_number << 15 | function_number << 12);

                    const pci_request_vaddr = kernel_memory.physical_to_virtual(pci_request_paddr) catch |e| {
                        toolbox.panic("Error finding descriptor address 0x{X}. Error: {} ", .{ pci_request_paddr, e });
                    };
                    const pcie_device_header = @as([*]align(4096) u8, @ptrFromInt(pci_request_vaddr))[0..64];
                    if (pcie_device_header[0] == 0xFF and pcie_device_header[1] == 0xFF) {
                        if (function_number == 0) {
                            if (max_bus_opt == null and device_number == 0) {
                                break :bus_loop;
                            }
                            continue :device_loop;
                        }
                        continue :function_loop;
                    }
                    const header_type = pcie_device_header[HEADER_TYPE_BYTE_OFFSET] & 0x7F;
                    if (header_type == BRIDGE_DEVICE_HEADER_TYPE) {
                        const pcie_bridge_device: *align(4096) volatile BridgeDeviceHeader =
                            @ptrCast(pcie_device_header);

                        if (max_bus_opt) |max_bus| {
                            if (pcie_bridge_device.subordinate_bus_number + 1 > max_bus) {
                                max_bus_opt = pcie_bridge_device.subordinate_bus_number + 1;
                            }
                        } else {
                            max_bus_opt = pcie_bridge_device.subordinate_bus_number + 1;
                        }
                        const physical_bars: []volatile u32 = &pcie_bridge_device.base_address_registers;
                        const command_register = &pcie_bridge_device.command;
                        const base_address_registers =
                            map_base_address_register_into_virtual_memory(
                            physical_bars,
                            command_register,
                            arena,
                        );
                        ret.append(.{
                            .device = device_number,
                            .bus = bus,
                            .function = function_number,
                            .header = pcie_bridge_device,
                            .header_type = .BridgeDevice,
                            .base_address_registers = base_address_registers,
                            .config_data = @as([*]volatile u8, @ptrFromInt(pci_request_vaddr))[0..4096],
                        });
                    } else {
                        const pcie_endpoint_device_header: *align(4096) EndPointDeviceHeader =
                            @ptrCast(pcie_device_header);
                        const physical_bars: []volatile u32 = &pcie_endpoint_device_header.base_address_registers;
                        const command_register = &pcie_endpoint_device_header.command;
                        const base_address_registers =
                            map_base_address_register_into_virtual_memory(
                            physical_bars,
                            command_register,
                            arena,
                        );
                        const device = .{
                            .device = device_number,
                            .bus = bus,
                            .function = function_number,
                            .header = pcie_endpoint_device_header,
                            .header_type = .EndPointDevice,
                            .base_address_registers = base_address_registers,
                            .config_data = @as([*]volatile u8, @ptrFromInt(pci_request_vaddr))[0..4096],
                        };
                        disable_msi_and_msix(device);
                        ret.append(device);
                    }
                }
            }
        }
    }
    return ret.items();
}

//TODO: not sure if necessary?
fn disable_msi_and_msix(device: Device) void {
    const end_point_device_header = device.end_point_device_header();
    var offset = end_point_device_header.capabilities_pointer;
    var cap_header_cursor = device.get_config_data(
        CapabilityHeader,
        offset,
    );
    while (cap_header_cursor) |cap_header| {
        switch (cap_header.capability_id) {
            MSI_CAPABILITY_ID => {
                const msi: *volatile MSICapabilityHeader = @ptrCast(cap_header);
                msi.* = .{};
            },
            MSI_X_CAPABILITY_ID => {
                const msix: *volatile MSIXCapabilityHeader = @ptrCast(cap_header);
                msix.* = .{};
            },
            else => {},
        }
        offset = cap_header.next_pointer;
        cap_header_cursor = device.get_config_data(
            CapabilityHeader,
            offset,
        );
    }
}
pub const InstallInterruptResult = struct {
    vector: usize = 0,
    //TODO: change to enum and get rid of panic
    success: bool = false,
};
pub fn install_interrupt_hander(
    device: Device,
    comptime handler: kernel.InterruptHandler,
) InstallInterruptResult {
    const end_point_device_header = device.end_point_device_header();
    var offset = end_point_device_header.capabilities_pointer;
    const msi_x_capability_structure = b: {
        var cap_header_cursor = device.get_config_data(
            CapabilityHeader,
            offset,
        );
        while (cap_header_cursor) |cap_header| {
            if (cap_header.capability_id == MSI_X_CAPABILITY_ID) {
                break :b @as(*volatile MSIXCapabilityStructure, @ptrCast(cap_header));
            }
            offset = cap_header.next_pointer;
            cap_header_cursor = device.get_config_data(
                CapabilityHeader,
                offset,
            );
        }
        toolbox.panic("We do not currently support non-MSI-X USB XHCI controllers", .{});
    };
    const BIR_MASK = MSIXCapabilityStructure.BIR_MASK;
    msi_x_capability_structure.header.message_control.enable = true;

    const paddr_bar_index = msi_x_capability_structure.table_offset & BIR_MASK;
    switch (paddr_bar_index) {
        0, 2, 4 => {},
        else => {
            echo_line("Bad paddr_bar_index: {}", .{paddr_bar_index});
            //TODO: log error
            return .{};
        },
    }

    const bar_index = paddr_bar_index / 2;
    const bar_opt = device.base_address_registers[bar_index];
    if (bar_opt == null) {
        //TODO: log error
        return .{};
    }
    const bar = bar_opt.?;

    const StaticVars = struct {
        var vector: u8 = 32;
    };

    echo_line("installing vector: {}", .{StaticVars.vector});
    kernel.register_interrupt_handler(handler, StaticVars.vector);
    defer StaticVars.vector += 1;

    echo_line("BIR: {}, Physical: 0x{X} BARs: physical low: 0x{X}, high: 0x{X}", .{
        paddr_bar_index,
        effective_bar(
            end_point_device_header.base_address_registers[0],
            end_point_device_header.base_address_registers[1],
        ) catch 0,
        end_point_device_header.base_address_registers[0],
        end_point_device_header.base_address_registers[1],
    });
    echo_line("BARs virtual: 0x{X}, physical: 0x{X}, Core ID: {}", .{
        @intFromPtr(bar.ptr),
        kernel_memory.virtual_to_physical(@intFromPtr(bar.ptr)) catch 0,
        w64.get_core_id(),
    });
    const msi_x_table = msi_x_capability_structure.table(bar);
    for (msi_x_table, 0..) |*entry, i| {
        _ = i; // autofix
        const vector_control = MSIXVectorControl{ .disabled = true };
        entry.write_register(vector_control);
    }

    const first_entry = &msi_x_table[0];
    first_entry.write_register(MSIXAMD64MessageAddress{
        .destination_id = @intCast(w64.get_core_id()),
    });
    //zero-out reserved field in table entry
    first_entry.data[MSIXAMD64MessageAddress.DWORD_OFFSET + 1] = 0;

    first_entry.write_register(MSIXAMD64MessageData{
        .vector = StaticVars.vector,
    });
    first_entry.write_register(MSIXVectorControl{ .disabled = false });

    echo_line("MSI-X message address: 0x{X} message data: 0x{X}", .{
        first_entry.data[MSIXAMD64MessageAddress.DWORD_OFFSET],
        first_entry.data[MSIXAMD64MessageData.DWORD_OFFSET],
    });
    echo_line("first_entry vector: {}, static var vector: {}", .{
        first_entry.read_register(MSIXAMD64MessageData).vector,
        StaticVars.vector,
    });

    return .{ .success = true, .vector = StaticVars.vector };
}

fn bar_address_space_size(
    comptime BARSize: type,
    physical_bars: []volatile u32,
    command_register: *volatile DeviceCommandRegister,
    bar_index: usize,
) usize {
    //TODO:
    // if (bar_index >= device.base_address_registers.len) {
    //     //TODO: log error
    //     return result;
    // }
    var command_to_restore = command_register.*;
    var command = command_to_restore;
    command.io_mapped = false;
    command.memory_mapped = false;
    command.interrupt_disabled = true;
    command_register.* = command;

    defer {
        //TODO: I _think_ this is only for MSI? If so, we want it disabled since we only support MSI-X right now
        //Need to make sure of this.
        command_to_restore.interrupt_disabled = true;

        command_register.* = command_to_restore;
    }

    //Find size of MMIO space per https://wiki.osdev.org/PCI#Address_and_size_of_the_BAR
    const bar_ptr: *volatile BARSize = @ptrCast(@alignCast(&physical_bars[bar_index]));

    const bar_data = bar_ptr.*;
    defer bar_ptr.* = bar_data;

    //writing all 1s to the bar register will give the 2s compliment of the size
    bar_ptr.* = ~@as(BARSize, 0);

    //we need to mask off the bottom 4 bits
    const size = ~((bar_ptr.* & ~@as(BARSize, 0xF))) +% 1;

    return size;
}

fn map_base_address_register_into_virtual_memory(
    physical_bars: []volatile u32,
    command_register: *volatile DeviceCommandRegister,
    arena: *toolbox.Arena,
) []?BaseAddressRegisterData {
    toolbox.assert(
        physical_bars.len > 0 and physical_bars.len % 2 == 0,
        "physical_bars.len must be even, but was: {any}",
        .{physical_bars},
    );

    const virtual_bars = arena.push_slice_clear(?BaseAddressRegisterData, physical_bars.len / 2);
    var i: usize = 0;
    while (i < physical_bars.len) : (i += 2) {
        const low = physical_bars[i];
        const high = physical_bars[i + 1];
        if (low == 0 and high == 0) {
            //unimpelemented bar.  skipping...
            continue;
        }
        const effective_physical_bar = effective_bar(low, high) catch {
            //TODO: log error
            continue;
        };
        const len = if (is_64_bit_bar(low)) bar_address_space_size(
            u64,
            physical_bars,
            command_register,
            i,
        ) else bar_address_space_size(
            u32,
            physical_bars,
            command_register,
            i,
        );
        if (!toolbox.is_aligned_to(len, w64.MMIO_PAGE_SIZE)) {
            //TODO: log error
            echo_line("Bad alignment for bar: low: 0x{X}, high: 0x{X}, len: {}", .{ low, high, len });
            continue;
        }
        const virtual_bar = kernel_memory.map_mmio_physical_address(
            effective_physical_bar,
            len / w64.MMIO_PAGE_SIZE,
        );
        const bar_data = @as([*]u8, @ptrFromInt(virtual_bar))[0..len];
        virtual_bars[i / 2] = bar_data;
    }
    {
        //TODO: validate to make sure at least one bar is implemented
    }
    return virtual_bars;
}

fn effective_bar(bar_low: u32, bar_high: u32) !u64 {
    if (is_io_space(bar_low)) {
        //TODO: log error
        return error.UnsupportedBARType;
    }
    if (is_64_bit_bar(bar_low)) {
        return (@as(u64, bar_low) & 0xFFFF_FFF0) + (@as(u64, bar_high) << 32);
    } else {
        return bar_low & 0xFFFF_FFF0;
    }
}

inline fn is_64_bit_bar(bar_low: u32) bool {
    return bar_low & 4 != 0;
}
inline fn is_io_space(bar_low: u32) bool {
    return bar_low & 1 != 0;
}

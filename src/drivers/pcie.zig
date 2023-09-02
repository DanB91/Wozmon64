const amd64 = @import("../amd64.zig");
const toolbox = @import("toolbox");
const w64 = @import("../wozmon64.zig");

pub const END_POINT_DEVICE_HEADER_TYPE = 0;
pub const BRIDGE_DEVICE_HEADER_TYPE = 1;
pub const HEADER_TYPE_BYTE_OFFSET = 0xE;
pub const MASS_STORAGE_CLASS_CODE = 0x1;
pub const NVME_SUBCLASS_CODE = 0x8;
pub const SERIAL_BUS_CLASS_CODE = 0xC;
pub const USB_SUBCLASS_CODE = 0x3;
pub const EHCI_PROGRAMING_INTERFACE = 0x20;
pub const XHCI_PROGRAMING_INTERFACE = 0x30;
pub const Device = struct {
    device: u64,
    function: u64,
    bus: u64,
    header: DeviceHeader,
    config_data: []volatile u8,

    pub fn get_config_data(self: *Device, comptime Data: type, byte_offset: usize) Data {
        comptime {
            toolbox.static_assert(@sizeOf(Data) % 4 == 0);
        }
        return @as(*Data, @ptrCast(@alignCast(self.config_data[byte_offset .. byte_offset + @sizeOf(Data)].ptr))).*;
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

const DeviceHeaderType = enum(u8) {
    EndPointDevice,
    BridgeDevice,
    _,
};
pub const CapabilityHeader = extern struct {
    capability_id: u8 align(1),
    next_pointer: u8 align(1),
    reserved: u16 align(1),
};
pub const DeviceHeader = union(DeviceHeaderType) {
    EndPointDevice: *align(4096) volatile EndPointDeviceHeader,
    BridgeDevice: *align(4096) volatile BridgeDeviceHeader,
    const StatusRegister = packed struct(u16) {
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
    const CommandRegister = packed struct(u16) {
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
};
pub const EndPointDeviceHeader = extern struct {
    vendor_id: u16 align(1),
    device_id: u16 align(1),
    command: DeviceHeader.CommandRegister align(1),
    status: DeviceHeader.StatusRegister align(1),
    revision_id: u8 align(1),
    programming_interface_byte: u8 align(1),
    subclass_code: u8 align(1),
    class_code: u8 align(1),
    cache_line_size: u8 align(1),
    latency_timer: u8 align(1),
    header_type: u8 align(1),
    built_in_self_test: u8 align(1),
    bar0: u32 align(1),
    bar1: u32 align(1),
    bar2: u32 align(1),
    bar3: u32 align(1),
    bar4: u32 align(1),
    bar5: u32 align(1),
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

    pub fn effective_bar0(self: EndPointDeviceHeader) u64 {
        if ((self.bar0 & 0x4) != 0) {
            //64 bit address
            return (@as(u64, self.bar0) & 0xFFFF_FFF0) + (@as(u64, self.bar1) << 32);
        } else {
            return @as(u64, self.bar0) & 0xFFFF_FFF0;
        }
    }
};
pub const BridgeDeviceHeader = extern struct {
    vendor_id: u16 align(1),
    device_id: u16 align(1),
    command: DeviceHeader.CommandRegister align(1),
    status: DeviceHeader.StatusRegister align(1),
    revision_id: u8 align(1),
    programming_interface_byte: u8 align(1),
    subclass_code: u8 align(1),
    class_code: u8 align(1),
    cache_line_size: u8 align(1),
    latency_timer: u8 align(1),
    header_type: u8 align(1),
    built_in_self_test: u8 align(1),
    bar0: u32 align(1),
    bar1: u32 align(1),
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
}

pub fn enumerate_devices(
    root_xsdt: *const amd64.XSDT,
    arena: *toolbox.Arena,
    memory_mappings: toolbox.RandomRemovalLinkedList(w64.VirtualMemoryMapping),
) []const Device {
    var ret = toolbox.DynamicArray(Device).init(arena, 32);
    const mcfg = amd64.find_acpi_table(root_xsdt, memory_mappings, "MCFG", MCFG) catch
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
            device_loop: for (0..32) |device| {
                function_loop: for (0..8) |function| {
                    const pci_request_paddr = pd.base_address +
                        ((bus - pd.start_pci_bus_number) << 20 | device << 15 | function << 12);

                    const pci_request_vaddr = w64.physical_to_virtual(pci_request_paddr, memory_mappings) catch |e| {
                        toolbox.panic("Error finding descriptor address {x}. Error: {} ", .{ pci_request_paddr, e });
                    };
                    const pcie_device_header = @as([*]align(4096) u8, @ptrFromInt(pci_request_vaddr))[0..64];
                    if (pcie_device_header[0] == 0xFF and pcie_device_header[1] == 0xFF) {
                        if (function == 0) {
                            if (max_bus_opt == null and device == 0) {
                                break :bus_loop;
                            }
                            continue :device_loop;
                        }
                        continue :function_loop;
                    }
                    const header_type = pcie_device_header[HEADER_TYPE_BYTE_OFFSET] & 0x7F;
                    if (header_type == BRIDGE_DEVICE_HEADER_TYPE) {
                        const pcie_bridge_device = @as(*align(4096) volatile BridgeDeviceHeader, @ptrCast(pcie_device_header));
                        if (max_bus_opt) |max_bus| {
                            if (pcie_bridge_device.subordinate_bus_number + 1 > max_bus) {
                                max_bus_opt = pcie_bridge_device.subordinate_bus_number + 1;
                            }
                        } else {
                            max_bus_opt = pcie_bridge_device.subordinate_bus_number + 1;
                        }
                        ret.append(.{
                            .device = device,
                            .bus = bus,
                            .function = function,
                            .header = .{ .BridgeDevice = pcie_bridge_device },
                            .config_data = @as([*]volatile u8, @ptrFromInt(pci_request_vaddr))[0..4096],
                        });
                    } else {
                        ret.append(.{
                            .device = device,
                            .bus = bus,
                            .function = function,
                            .header = .{ .EndPointDevice = @as(*align(4096) volatile EndPointDeviceHeader, @ptrCast(pcie_device_header)) },
                            .config_data = @as([*]volatile u8, @ptrFromInt(pci_request_vaddr))[0..4096],
                        });
                    }
                }
            }
        }
    }
    return ret.items();
}

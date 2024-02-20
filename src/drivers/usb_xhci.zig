const std = @import("std");
const toolbox = @import("toolbox");
//TODO remove in favor of toolbox
const kernel = @import("../kernel.zig");
const amd64 = @import("../amd64.zig");
const pcie = @import("pcie.zig");
const usb_hid = @import("usb_hid.zig");
const w64 = @import("../wozmon64_kernel.zig");
const kernel_memory = @import("../kernel_memory.zig");
const static_assert = toolbox.static_assert;

const echo_line = kernel.echo_line;
const profiler = toolbox.profiler;

//TODO: for debugging on desktop
// pub fn echo_line(comptime fmt: []const u8, args: anytype) void {
//     _ = args;
//     _ = fmt;
// }

pub const Controller = struct {
    pcie_descriptor: pcie.Device,
    arena: *toolbox.Arena,
    capability_registers: *volatile CapabilityRegisters,
    interrupter_registers: *volatile InterrupterRegisters,
    operational_registers: *volatile OperationalRegisters,
    doorbells: []volatile u32,

    //everything below is allocated on the arena
    command_ring: *volatile CommandRing,
    event_ring: *volatile EventRing,

    event_response_map: EventResponseMap,
    event_response_map_arena: *toolbox.Arena,

    interrupt_vector: usize,

    device_slots: []DeviceContextPointer,
    root_hub_usb_ports: []volatile PortRegisters,

    devices: toolbox.RandomRemovalLinkedList(*Device),
};
pub const EventResponseMap = toolbox.HashMap(usize, PollEventRingResult);

pub const Device = struct {
    is_connected: bool,
    parent_controller: *Controller,
    arena: *toolbox.Arena,
    port_id: usize,
    port_registers: *volatile PortRegisters,
    input_context: InputContext,
    output_device_context: DeviceContext,

    manufacturer: ?[]const u8,
    product: ?[]const u8,
    serial_number: ?[]const u8,

    descriptor_data: []u8,
    number_of_unsupported_interfaces: usize,
    endpoint_0_transfer_ring: *TransferRing,
    interfaces: []Interface,
    hid_devices: toolbox.RandomRemovalLinkedList(usb_hid.USBHIDDevice),
};

pub const Interface = struct {
    parent_device: *Device,
    class_data: ClassData,
    interface_number: u8,
    endpoints: []Endpoint,
    number_of_unsupported_endpoints: usize,

    pub const ClassData = union(InterfaceClass) {
        Audio: void,
        CommunicationsAndCDCControl: void,
        HID: struct { hid_descriptor: usb_hid.Descriptor },
        Physical: void,
        Image: void,
        Printer: void,
        MassStorage: void,
        Hub: void,
        CDCData: void,
        SmartCard: void,
        ContentSecurity: void,
        Video: void,
        PersonalHealthcare: void,
        AudioVideoDevices: void,
        BillboardDevice: void,
        USBTypeCBridge: void,
        DiagnosticDevice: void,
        WirelessController: void,
        Miscellaneous: void,
        ApplicationSpecific: void,
        VendorSpecific: void,
    };
};
pub const Endpoint = struct {
    parent_interface: *Interface,
    transfer_ring: *volatile TransferRing,
    endpoint_number: u4,
    doorbell_value: u32,
    endpoint_context: *volatile EndpointContext,
    direction: USBEndpointDescriptor.Direction,
    transfer_type: EndpointTransferType,
};
//TODO just make these constants.  Descriptor type really can be any value
pub const DescriptorType = enum(u8) {
    Invalid = 0,
    Device = 1,
    Configuration = 2,
    String = 3,
    Interface = 4,
    Endpoint = 5,
    HID = 0x21,
    _,
};
pub const InterfaceClass = enum(u8) {
    Audio = 0x1,
    CommunicationsAndCDCControl = 0x2,
    HID = 0x3,
    Physical = 0x5,
    Image = 0x6,
    Printer = 0x7,
    MassStorage = 0x8,
    Hub = 0x9,
    CDCData = 0xA,
    SmartCard = 0xB,
    ContentSecurity = 0xC,
    Video = 0xE,
    PersonalHealthcare = 0xF,
    AudioVideoDevices = 0x10,
    BillboardDevice = 0x11,
    USBTypeCBridge = 0x12,
    DiagnosticDevice = 0xDC,
    WirelessController = 0xE0,
    Miscellaneous = 0xEF,
    ApplicationSpecific = 0xFE,
    VendorSpecific = 0xFF,
    _,
};
const DeviceContextPointer = u64;
const ScratchPadBufferPointer = u64;
const InputContext = struct {
    context_size_in_words: usize,
    physical_address: u64,
    data: []volatile u32,
};
const InputControlContext = extern struct {
    drop_context_flags: u32 align(1),
    add_context_flags: u32 align(1),
    reserved0: u32 align(1),
    reserved1: u32 align(1),
    reserved2: u32 align(1),
    reserved3: u32 align(1),
    reserved4: u32 align(1),
    configuration_value: u8 align(1),
    interface_number: u8 align(1),
    alternate_setting: u8 align(1),
    reserved5: u8 align(1),
};
const DeviceContext = struct {
    context_size_in_words: usize,
    physical_address: u64,
    data: []volatile u32,
};
const EndpointTransferType = enum(u2) {
    Control,
    Isochronous,
    Bulk,
    Interrupt,
};
const SlotContext = packed struct {
    route_string_tier_1: u4,
    route_string_tier_2: u4,
    route_string_tier_3: u4,
    route_string_tier_4: u4,
    route_string_tier_5: u4,
    speed: PortSpeed,
    reserved0: u1,
    mtt: bool, //Multi-TT
    is_hub: bool,
    context_entries: u5,
    max_exit_latency: u16,
    root_hub_port_number: u8,
    number_of_ports: u8,
    parent_slot_id: u8,
    parent_port_number: u8,
    ttt: enum(u2) {
        AtMost8FSBitTimes = 0,
        AtMost16FSBitTimes,
        AtMost24FSBitTimes,
        AtMost32FSBitTimes,
    },
    reserved: u4 = 0,
    interrupter_target: u10,
    usb_device_address: u27,
    slot_state: enum(u5) {
        DisabledOrEnabledWhoKnows,
        Default,
        Addressed,
        Configured,
        _,
    },
    reserved1: u32,
    reserved2: u32,
    reserved3: u32,
    reserved4: u32,
};
const EndpointContext = packed struct {
    ep_state: enum(u3) { //endpoint state
        Disabled,
        Running,
        Halted,
        Stopped,
        Error,
        Reserved0,
        Reserved1,
        Reserved2,
    } = .Disabled,
    reserved0: u5,
    mult: u2,
    max_p_streams: u5, //max primary streams
    lsa: enum(u1) {
        SecondaryStreamsEndabled,
        SecondaryStreamsDisabled,
    }, //Linear Stream Array
    interval: u8,
    max_esit_payload_hi: u8, //Max Endpoint Service Time Interval Payload High
    reserved1: u1,
    cerr: u2, //error count
    transfer_type: EndpointTransferType, //aka EP Type
    is_control_or_input_endpoint: bool,
    reserved2: u1,
    hid: bool, //Host Initiate Disable
    max_burst_size: u8,
    max_packet_size: u16,
    dcs: u1, //Dequeue Cycle State
    reserved3: u3,
    tr_dequeue_pointer: u60, // Transfer Ring Dequeue Pointer (really a 64 bit address)
    average_trb_length: u16,
    max_esit_payload_lo: u16, //Max Endpoint Service Time Interval Payload Low
    reserved4: u32,
    reserved5: u32,
    reserved6: u32,
};
const CapabilityRegisters = packed struct {
    length: u8, //CAPLENGTH
    reserved: u8,
    version: u16, //HCIVERSION
    structural_parameters1: u32, //HCSPARAMS1
    structural_parameters2: u32, //HCSPARAMS2
    structural_parameters3: u32, //HCSPARAMS3
    capability_parameters1: u32, //HCCPARAMS1
    doorbell_offset: u32, //DBOFF
    runtime_registers_space_offset: u32, //RTSOFF
    capability_parameters2: u32, //HCCPARAMS2

    fn read_register(self: *volatile CapabilityRegisters, comptime RegisterType: type) RegisterType {
        switch (RegisterType) {
            StructuralParameters1 => {
                const register = self.structural_parameters1;
                return @as(StructuralParameters1, @bitCast(register));
            },
            StructuralParameters2 => {
                const register = self.structural_parameters2;
                return @as(StructuralParameters2, @bitCast(register));
            },
            HCCPARAMS1 => {
                const register = self.capability_parameters1;
                return @as(HCCPARAMS1, @bitCast(register));
            },
            else => {
                @compileError("CapabilityRegisters" ++ @typeName(RegisterType) ++ " not implemented yet");
            },
        }
    }

    const StructuralParameters1 = packed struct(u32) { //HCSPARAMS1
        //all read-only
        max_device_slots: u8, //MaxSlots
        number_of_interrupters: u16, //MaxIntrs really is only 11 bits
        max_ports: u8, //MaxPorts
    };
    const StructuralParameters2 = packed struct(u32) { //HCSPARAMS2
        //all read-only
        isochronous_scheduling_threshold: u4, //IST
        event_ring_segment_table_max: u17, // (only 4 bits) ERST Max
        max_scratchpad_buffers_hi: u5,
        scratch_pad_restore: bool, //SPR
        max_scratchpad_buffers_lo: u5,
    };
    const HCCPARAMS1 = packed struct {
        ac64: bool, //64-bit Addressing Capability
        bnc: bool, //BW Negotiation Capability
        csz: bool, //Context Size
        ppc: bool, //Port Power Control
        pind: bool, //Port Indicators
        lhrc: bool, //Light HC Reset Capability
        ltc: bool, //Latency Tolerance Messaging Capability
        nss: bool, //No Secondary SID Support
        pae: bool, //Parse All Event Data
        spc: bool, //Stopped - Short Packet Capability
        sec: bool, //Stopped EDTLA Capability
        cfc: bool, //Contiguous Frame ID Capability
        max_psa_size: u4, //Maximum Primary Stream Array Size
        xecp: u16, //xHCI Extended Capabilities Pointer
    };
};
const OperationalRegisters = extern struct {
    command: u32 align(4), //USBCMD 0
    status: u32 align(4), //USBSTS 4
    page_size: u32 align(4), //PAGESIZE 8
    reserved1: u32 align(4), //0xC
    reserved2: u32 align(4), //0xC
    device_notification_control_lo: u32 align(4), //DNCTRL //0x14
    command_ring_control_lo: u32 align(4), //CRCR 0x18
    command_ring_control_hi: u32 align(4), //CRCR 0x1C
    reserved3: u32 align(4), //0x20
    reserved4: u32 align(4), //0x24
    reserved5: u32 align(4), //0x28
    reserved6: u32 align(4), //0x2C
    device_context_base_address_array_pointer_lo: u32 align(4), //DCBAAP 0x30
    device_context_base_address_array_pointer_hi: u32 align(4), //DCBAAP 0x34
    config: u32 align(4), //CONFIG 0x38

    const USBCommand = packed struct(u32) { //USBCMD
        run_stop: bool, //R/S - read-write
        host_controller_reset: bool, //HCRST - read-write
        interrupter_enable: bool, //INTE - read-write
        host_system_error_enable: bool, //HSEE - read-write
        reserved1: u3,
        light_host_controller_reset: bool, //LHCRST - read-only or read-write
        controller_save_state: bool, //CSS read-write
        controller_restore_state: bool, //CRS read-write
        enable_wrap_event: bool, //EWE read-write
        enable_u3_mfindex_stop: bool, //EU3S read-write
        reserved2: u1,
        cem_enable: bool, //CME read-write
        extended_tbc_enable: bool, //ETE read-write
        extended_tbc_trb_status_enable: bool, //TSC_EN read-write
        vtio_enable: bool, //VTIOE read-write
        reserved3: u15,
    };
    const USBStatus = packed struct(u32) { //USBSTS
        hc_halted: bool, //HCH - read-only
        reserved1: u1,
        host_system_error: bool, //HSE - write "true" to clear
        event_interrupt: bool, //EINT - write "true" to clear
        port_change_detect: bool, //PCD - write "true" to clear
        reserved2: u1,
        reserved3: u1,
        reserved4: u1,

        save_state_status: u1, //SSS - read-only
        restore_state_status: u1, //RSS - read-only
        save_restore_error: bool, //SRE - write "true" to clear
        controller_not_ready: bool, //CNR - read-only
        host_controller_error: bool, //HCE - read-only
        reserved5: u3,

        reserved6: u16,
    };

    const Config = packed struct(u32) { //CONFIG
        max_slots_enabled: u8, //MaxSlotsEn read-write
        u3_entry_enable: bool, //U3E read-write
        configuration_information_enable: bool, //CIE - read-write
        reserved1: u6,
        reserved2: u16,
    };
    fn read_register(self: *volatile OperationalRegisters, comptime RegisterType: type) RegisterType {
        @fence(.SeqCst);
        switch (RegisterType) {
            USBCommand => {
                const register = self.command;
                return @as(USBCommand, @bitCast(register));
            },
            USBStatus => {
                const register = self.status;
                return @as(USBStatus, @bitCast(register));
            },
            Config => {
                const register = self.config;
                return @as(Config, @bitCast(register));
            },
            else => {
                @compileError("OperationalRegisters" ++ @typeName(RegisterType) ++ " not implemented yet");
            },
        }
    }

    fn write_command_ring_control(self: *volatile OperationalRegisters, value: u64) void {
        self.command_ring_control_lo = @as(u32, @truncate(value));
        self.command_ring_control_hi = @as(u32, @truncate(value >> 32));
    }

    fn write_device_context_base_address_array_pointer(self: *volatile OperationalRegisters, value: u64) void {
        self.device_context_base_address_array_pointer_lo = @as(u32, @truncate(value));
        self.device_context_base_address_array_pointer_hi = @as(u32, @truncate(value >> 32));
    }

    fn write_register(self: *volatile OperationalRegisters, value: anytype) void {
        const ValueType = @TypeOf(value);

        const ptr: *volatile u32 = switch (ValueType) {
            USBCommand => &self.command,
            USBStatus => &self.status,
            Config => &self.config,
            else => {
                @compileError("OperationalRegisters" ++ @typeName(ValueType) ++ " not implemented yet");
            },
        };
        //TODO: Zig bug.  The below line doesn't work
        //ptr.* = @bitCast(u32, value);

        const int_value: u32 = @as(u32, @bitCast(value));
        ptr.* = int_value;
        @fence(.SeqCst);
    }
};

const InterrupterRegisters = packed struct {
    iman: packed struct(u32) {
        ip: bool = false, //Interrupt Pending
        ie: bool, //Interrupt enable
        reserved: u30 = 0,
    }, //Interrupter Management -- Runtime register 0x20
    imod: packed struct(u32) {
        imodi: u16, //interval
        imodc: u16, //counter
    }, //Interrupter Moderation 0x24
    erstsz: u32, //Event Ring Segment Table Size -- Runtime register 0x28
    reserved: u32 = 0, //Runtime register 0x2C
    erstba: packed struct(u64) {
        reserved: u6 = 0,
        base_address: u58,
    }, //Event Ring Segment Table Base Address -- Runtime Register 0x30
    erdp: EventRingDequeuePointer, //Event Ring Dequeue Pointer -- Runtime Register 0x38
};

const PortRegisters = packed struct {
    portsc: u32,
    portpmsc: u32,
    portli: u32,
    reserved: u32,
    fn read_register(self: *const volatile PortRegisters, comptime RegisterType: type) RegisterType {
        switch (RegisterType) {
            StatusAndControlRegister => {
                const register = self.portsc;
                return @as(StatusAndControlRegister, @bitCast(register));
            },
            else => {
                @compileError("OperationalRegisters" ++ @typeName(RegisterType) ++ " not implemented yet");
            },
        }
    }

    fn write_register(self: *volatile PortRegisters, value: anytype) void {
        const ValueType = @TypeOf(value);
        switch (ValueType) {
            StatusAndControlRegister => {
                const int_value: u32 = @as(u32, @bitCast(value));
                self.portsc = int_value;
            },
            else => {
                @compileError("OperationalRegisters" ++ @typeName(ValueType) ++ " not implemented yet");
            },
        }
    }
    const StatusAndControlRegister = packed struct {
        current_connect_status: bool, //CCS read-only
        port_enabled_disabled: bool, //PED read, write "true" to clear
        reserved1: u1,
        over_current_active: bool, //OCA read-only
        port_reset: bool, //PR read-write "true" to reset
        port_link_state: enum(u4) { //PLS read-write
            U0,
            U1,
            U2,
            U3, //(Device Suspended)
            Disabled,
            RxDetect,
            Inactive,
            Polling,
            Recovery,
            HotReset,
            ComplianceMode,
            TestMode,
            Reserved1,
            Reserved2,
            Reserved3,
            Resume,
        },
        port_power: bool, //PP read-write
        port_speed: PortSpeed, //PS read-only TODO create enum
        port_indicator_control: enum(u2) { //read-write depending on HCCPARAMS1.PIND
            PortIndicatorsOff,
            Amber,
            Green,
            Undefined,
        },

        port_link_state_write_strobe: u1, //PLS read-write
        connect_status_change: bool, //CSC (read-write)
        port_enabled_disabled_change: bool, //PEC read, write "true" to clear
        warm_port_reset_change: bool, //WRC read, write "true" to clear
        over_current_change: bool, //OCC read, write "true" to clear
        port_reset_change: bool, //PRC read, write "true" to clear
        port_link_state_change: bool, //PLC read, write "true" to clear
        port_config_error_change: bool, //CEC read, write "true" to clear
        cold_attach_status: bool, //CAS read-only
        wake_on_connect_enable: bool, //WCE read-write
        wake_on_disconnect_enable: bool, //WDE read-write
        wake_on_over_current_enable: bool, //WOE read-write
        reserved2: u2,
        device_removable: bool, //DR read-only
        warm_port_reset: bool, //WPR read, write "true" to start reset

        //The PED and PR flags are mutually exclusive. Writing the PORTSC register with PED and PR set to ‘1’ shall result in undefined behavior.

    };
};
const PortSpeed = enum(u4) {
    Invalid,
    FullSpeed,
    LowSpeed,
    HighSpeed,
    SuperSpeed,
    _,
};
pub const NormalTRB = packed struct {
    data_buffer_pointer: u64,
    trb_transfer_length: u17,
    td_size: u5,
    interrupter_target: u10,
    cycle_bit: u1,
    ent: bool, //evaluate next trb
    isp: bool, //interrupt on short packet
    ns: bool, //no snoop
    ch: u1, //chain bit
    ioc: bool, //interrupt on completion
    idt: bool, //immediate data
    reserved1: u2,
    bei: bool, //block event interrupt
    trb_type: u6,
    reserved2: u16,
};
const SetupStageTRB = packed struct {
    bm_request_type: u8,
    b_request: u8,
    w_value: u16,
    w_index: u16,
    w_length: u16,
    trb_transfer_length: u17,
    reserved0: u5,
    interrupter_target: u10,
    cycle_bit: u1,
    reserved1: u4,
    ioc: bool, //interrupt on completion
    idt: bool, //immediate data.  always true
    reserved2: u3,
    trb_type: u6,
    trt: enum(u16) {
        NoDataStage,
        Reserved,
        OutDataStage,
        InDataStage,
        _,
    }, //transfer type

};
const StatusStageTRB = packed struct {
    reserved1: u86,
    interrupter_target: u10,
    cycle_bit: u1,
    ent: bool, //evaluate next trb
    reserved2: u2,
    ch: u1, //chain bit
    ioc: bool, //interrupt on completion
    reserved3: u4,
    trb_type: u6,
    dir: enum(u1) {
        HostToDevice,
        DeviceToHost,
    }, //direction
    reserved4: u15,
};
const DataStageTRB = packed struct {
    data_buffer_address: u64,
    trb_transfer_length: u17,
    td_size: u5,
    interrupter_target: u10,
    cycle_bit: u1,
    ent: bool, //evaluate next trb
    isp: bool, //interrupt on short packet
    ns: bool, //no snoop
    ch: u1, //chain bit
    ioc: bool, //interrupt on completion
    idt: bool, //immediate data
    reserved1: u3,
    trb_type: u6,
    dir: enum(u1) {
        HostToDevice,
        DeviceToHost,
    }, //direction
    reserved4: u15,
};

const USBDescriptorHeader = packed struct {
    length: u8,
    descriptor_type: DescriptorType,
};
const USBDeviceDescriptor = extern struct {
    length: u8,
    descriptor_type: DescriptorType,
    usb_version: u16,
    device_class: u8,
    device_subclass: u8,
    device_protocol: u8,
    max_packet_size: u8,
    vendor: u16,
    product: u16,
    device: u16,
    manufacturer_index: u8,
    product_index: u8,
    serial_number_index: u8,
    num_configurations: u8,
};
const USBConfigurationDescriptor = extern struct {
    length: u8 align(1),
    descriptor_type: DescriptorType align(1),
    total_length: u16 align(1),
    num_interfaces: u8 align(1),
    configuration_value: u8 align(1),
    configuration_index: u8 align(1),
    attributes: u8 align(1),
    max_power: u8 align(1),
};
const USBInterfaceDescriptor = extern struct {
    length: u8 align(1),
    descriptor_type: DescriptorType align(1),
    interface_number: u8 align(1),
    alternate_setting: u8 align(1),
    num_endpoints: u8 align(1),
    interface_class: InterfaceClass align(1),
    interface_subclass: u8 align(1),
    interface_protocol: u8 align(1),
    interface_index: u8 align(1),
};
const USBEndpointDescriptor = packed struct {
    length: u8,
    descriptor_type: DescriptorType,
    endpoint_address: u8,
    attributes: u8,
    max_packet_size: u16,
    interval: u8,

    const Direction = enum(u1) { Out, In };
    const SynchronizationType = enum(u2) {
        NoSynchronization,
        Asynchronous,
        Adaptive,
        Synchronous,
    };
    const InterruptUsageType = enum(u2) {
        Periodic,
        Notification,
        Reserved0,
        Reserved1,
    };
    const IsochronousUsageType = enum(u2) {
        DataEndpoint,
        FeedbackEndpoint,
        ImplicitFeedbackDataEndpoint,
        Reserved,
    };
    fn endpoint_number(self: *align(1) USBEndpointDescriptor) u4 {
        return @intCast(self.endpoint_address & 0xF);
    }
    fn direction(self: *align(1) USBEndpointDescriptor) Direction {
        return @enumFromInt(@as(u1, @intCast(self.endpoint_address >> 7)));
    }
    fn transfer_type(self: *align(1) USBEndpointDescriptor) EndpointTransferType {
        return @enumFromInt(@as(u2, @intCast(self.attributes & 3)));
    }
    fn interrupt_usage_type(self: *align(1) USBEndpointDescriptor) InterruptUsageType {
        return @enumFromInt(@as(u2, @intCast((self.attributes >> 4) & 3)));
    }
    fn isochronous_usage_type(self: *align(1) USBEndpointDescriptor) IsochronousUsageType {
        return @enumFromInt(@as(u2, @intCast((self.attributes >> 4) & 3)));
    }
    fn synchronization_type(self: *align(1) USBEndpointDescriptor) SynchronizationType {
        return @enumFromInt(@as(u2, @intCast((self.attributes >> 2) & 3)));
    }
};

pub const TransferRequestBlock = packed struct {
    data_pointer: u64 = 0,
    status: u32 = 0,
    control: u32 = 0,

    pub fn write_cycle_bit(self: *volatile TransferRequestBlock, cs: u1) void {
        self.control &= 0xFFFF_FFFE;
        self.control |= @as(u32, cs);
    }
    pub fn read_cycle_bit(self: TransferRequestBlock) u1 {
        return @as(u1, @intCast(self.control & 1));
    }

    pub fn read_trb_type(self: TransferRequestBlock) Type {
        return @as(Type, @enumFromInt(@as(u6, @intCast(self.control >> 10 & 0x3F))));
    }

    pub fn read_slot_id(self: TransferRequestBlock) u8 {
        return @as(u8, @intCast(self.control >> 24));
    }
    pub fn read_completion_code(self: TransferRequestBlock) u8 {
        return @as(u8, @intCast(self.status >> 24));
    }
    pub fn read_number_of_bytes_not_transferred(self: TransferRequestBlock) u32 {
        return @as(u8, @intCast(self.status & 0xFFFFFF));
    }
    pub fn read_port_id(self: TransferRequestBlock) usize {
        return @as(usize, (self.data_pointer >> 24) & 0xFF);
    }

    pub const Type = enum(u6) {
        Reserved0 = 0,
        Normal = 1,
        SetupStage,
        DataStage,
        StatusStage,
        Isoch,
        Link,
        EventData,
        NoOp,
        EnableSlotCommand,
        DisableSlotCommand,
        AddressDeviceCommand,
        ConfigureEndpointCommand,
        EvaluateContextCommand,
        ResetEndpointCommand,
        StopEndpointCommand,
        SetTRDequeuePointerCommand,
        ResetDeviceCommand,
        ForceEventCommand,
        NegotiateBandwidthCommand,
        SetLatencyToleranceValueCommand,
        GetPortBandwidthCommand,
        ForceHeaderCommand,
        NoOpCommand,
        GetExtendedPropertyCommand,
        SetExtendedPropertyCommand,
        Reserved26 = 26,
        Reserved27 = 27,
        Reserved28 = 28,
        Reserved29 = 29,
        Reserved30 = 30,
        Reserved31 = 31,
        TransferEvent = 32,
        CommandCompletionEvent,
        PortStatusChangeEvent,
        BandwidthRequestEvent,
        DoorbellEvent,
        HostControllerEvent,
        DeviceNotificationEvent,
        MFINDEXWrapEvent,
        _,
    };
};
pub const TransferRequestBlockRing = struct {
    ring: [RING_SIZE]TransferRequestBlock = [_]TransferRequestBlock{.{}} ** RING_SIZE,
    index: usize = 0,
    cs: u1 = 0, //cycle state. starts at 1
    physical_address_start: u64 = 0,

    pub const RING_SIZE = 64;

    pub fn physical_address_of_current_index(self: TransferRequestBlockRing) usize {
        return self.physical_address_start + self.index * @sizeOf(TransferRequestBlock);
    }
};

pub const EventRing = struct {
    ring: TransferRequestBlockRing align(w64.MMIO_PAGE_SIZE),
    //must be aligned by 64 bytes
    event_ring_segment_entry: TransferRequestBlock align(64),
    erdp: *volatile EventRingDequeuePointer,
    event_trb_ring_physical_address: u64,
};
pub const CommandRing = struct {
    ring: TransferRequestBlockRing align(w64.MMIO_PAGE_SIZE),
    doorbell: *volatile u32,
};
pub const TransferRing = struct {
    trb_ring: TransferRequestBlockRing align(w64.MMIO_PAGE_SIZE),
    doorbell: *volatile u32,
};

const EventRingDequeuePointer = packed struct(u64) {
    // Dequeue ERST Segment Index.
    //We will default to zero since we only support one segment right now
    desi: u3 = 0,
    ehb: u1, // Event handler busy
    erdp: u60, //Event Ring Dequeue Pointer
};

const DeviceSlotDataStructures = struct {
    input_context: InputContext,
    output_device_context: DeviceContext,

    //TODO: rename to default_endpoint_trb_ring?
    endpoint_0_transfer_ring: *TransferRing,
    endpoint_0_transfer_ring_physical_address: u64,
};

const PollEventRingResult = struct {
    trb: TransferRequestBlock,
    number_of_bytes_not_transferred: u32,
    err: ?anyerror,
};

comptime {
    static_assert(@offsetOf(OperationalRegisters, "status") == 4, "Static assert failed");
    static_assert(@sizeOf(CapabilityRegisters) == 32, "Static assert failed");
    static_assert(@sizeOf(OperationalRegisters) == 60, "Static assert failed");
    static_assert(@sizeOf(InterrupterRegisters) == 32, "Static assert failed");
    static_assert(@sizeOf(TransferRequestBlock) == 16, "Static assert failed");
    static_assert(@sizeOf(USBDeviceDescriptor) == 18, "Static assert failed");
    //static_assert(@sizeOf(USBDeviceDescriptor) == 8, "Static assert failed");
    static_assert(@sizeOf(USBConfigurationDescriptor) == 9, "Static assert failed");
    static_assert(@sizeOf(USBInterfaceDescriptor) == 9, "Static assert failed");

    //bitSizeOf
    static_assert(@bitSizeOf(OperationalRegisters.USBCommand) == 32, "Static assert failed");
    static_assert(@bitSizeOf(OperationalRegisters.USBStatus) == 32, "Static assert failed");
    static_assert(@bitSizeOf(CapabilityRegisters.StructuralParameters1) == 32, "Static assert failed");
    static_assert(@bitSizeOf(CapabilityRegisters.StructuralParameters2) == 32, "Static assert failed");
    static_assert(@bitSizeOf(CapabilityRegisters.HCCPARAMS1) == 32, "Static assert failed");
    static_assert(@bitSizeOf(OperationalRegisters.Config) == 32, "Static assert failed");
    static_assert(@bitSizeOf(PortRegisters.StatusAndControlRegister) == 32, "Static assert failed");
    static_assert(@bitSizeOf(PortRegisters) == 128, "Static assert failed");

    static_assert(@offsetOf(EventRing, "event_ring_segment_entry") & 0x1F == 0, "Static assert failed");
    static_assert(@bitSizeOf(TransferRequestBlock) == 128, "Static assert failed");
    static_assert(@bitSizeOf(SetupStageTRB) == 128, "Static assert failed");
    static_assert(@bitSizeOf(StatusStageTRB) == 128, "Static assert failed");
    static_assert(@bitSizeOf(DataStageTRB) == 128, "Static assert failed");
    static_assert(@bitSizeOf(NormalTRB) == 128, "Static assert failed");
    static_assert(@bitSizeOf(EndpointContext) == 32 * 8, "Static assert failed");
    static_assert(@bitSizeOf(SlotContext) == 32 * 8, "Static assert failed");
    static_assert(@bitSizeOf(InputControlContext) == 32 * 8, "Static assert failed");
}

pub fn init(pcie_device: pcie.Device) !*Controller {
    profiler.begin("set up xhci controller");
    defer profiler.end();

    var controller_arena = toolbox.Arena.init(toolbox.mb(2));
    errdefer controller_arena.free_all();

    var pcie_device_header = pcie_device.end_point_device_header();
    {
        var command = pcie_device_header.command;
        command.io_mapped = false;
        command.memory_mapped = true;
        command.bus_master_dma_enabled = true;
        command.interrupt_disabled = false;
        pcie_device_header.command = command;
    }

    const bar0 = pcie_device.base_address_registers[0].?;
    echo_line("Found USB xHCI controller! ", .{});

    const capability_registers = bar_to_register(
        CapabilityRegisters,
        bar0,
        0,
    );
    const interrupter_registers = bar_to_register(
        InterrupterRegisters,
        bar0,
        capability_registers.runtime_registers_space_offset + 0x20,
    );

    echo_line("CR Len: {}", .{capability_registers.length});
    const operational_registers = bar_to_register(
        OperationalRegisters,
        bar0,
        capability_registers.length,
    );

    const hcsparams1 = capability_registers.read_register(CapabilityRegisters.StructuralParameters1);

    echo_line(
        "Detected xHCI device at with {} ports and {} slots.",
        .{ hcsparams1.max_ports, hcsparams1.max_device_slots },
    );
    {
        //stop the controller
        var command = operational_registers
            .read_register(OperationalRegisters.USBCommand);
        command.run_stop = false;
        operational_registers.write_register(command);
        var status = operational_registers
            .read_register(OperationalRegisters.USBStatus);

        //wait for controller to halt
        {
            profiler.begin("Wait for xHCI controller to halt");
            defer profiler.end();

            const timeout_ms = 100;
            const deadline_ms = toolbox.now().milliseconds() + timeout_ms;
            while (true) {
                if (status.hc_halted) {
                    break;
                }
                if (toolbox.now().milliseconds() >= deadline_ms) {
                    return error.TimeOutWaitingForControllerToBeHalted;
                }
                status = operational_registers
                    .read_register(OperationalRegisters.USBStatus);
                std.atomic.spinLoopHint();
            }
        }

        //reset controller
        command = @as(OperationalRegisters.USBCommand, @bitCast(@as(u32, 0)));
        command.host_controller_reset = true;
        operational_registers.write_register(command);

        //wait for controller to reset
        {
            profiler.begin("Wait for xHCI controller to reset");
            defer profiler.end();

            const timeout_ms = 100;
            const deadline_ms = toolbox.now().milliseconds() + timeout_ms;
            while (true) {
                if (!command.host_controller_reset) {
                    break;
                }
                if (toolbox.now().milliseconds() >= deadline_ms) {
                    return error.TimeOutWaitingForControllerToBeReset;
                }
                command = operational_registers
                    .read_register(OperationalRegisters.USBCommand);
                std.atomic.spinLoopHint();
            }
        }

        echo_line("xHCI controller reset!", .{});
    }

    //After Chip Hardware Reset wait until the Controller Not Ready (CNR) flag in the USBSTS is ‘0’
    //before writing any xHC Operational or Runtime registers.
    {
        var i: usize = 0;
        const timeout = 50;
        var status = operational_registers.read_register(OperationalRegisters.USBStatus);
        while (status.controller_not_ready) : ({
            i += 1;
            status = operational_registers.read_register(OperationalRegisters.USBStatus);
        }) {
            if (i >= timeout) {
                return error.TimeOutWaitingForControllerToBeReady;
            }
        }
    }

    //make sure that we support the kernel's page size
    if (w64.MMIO_PAGE_SIZE != (operational_registers.page_size << 12)) {
        return error.DoesNotSupportNativePageSize;
    }

    //Program the Device Context Base Address Array Pointer (DCBAAP) register (5.4.6) with a 64-bit address pointing to where the Device Context Base Address Array is located.
    //TODO

    //set all all slots as enabled
    {
        var config = operational_registers.read_register(OperationalRegisters.Config);
        config.max_slots_enabled = @as(u8, @intCast(hcsparams1.max_device_slots));
        operational_registers.write_register(config);
    }

    const doorbells: []volatile u32 =
        bar_to_slice(
        u32,
        bar0,
        capability_registers.doorbell_offset,
        hcsparams1.max_device_slots,
    );

    //inititalize Command Transfer Request Block Ring
    var command_trb_ring: *volatile CommandRing = undefined;
    {
        const command_trb_ring_allocation_result = alloc_object_aligned(
            CommandRing,
            w64.MMIO_PAGE_SIZE,
            controller_arena,
        );
        command_trb_ring = command_trb_ring_allocation_result.data;

        var ring: TransferRequestBlockRing = .{};
        initialize_trb_ring(&ring, command_trb_ring_allocation_result.physical_address_start, true);
        command_trb_ring.* = .{
            .ring = ring,
            .doorbell = &doorbells[0],
        };
        operational_registers.write_command_ring_control(
            command_trb_ring_allocation_result.physical_address_start | 1,
        );
    }

    var event_trb_ring: *volatile EventRing = undefined;
    var interrupt_vector: usize = 0;
    {
        const event_trb_ring_allocation_result = alloc_object_aligned(
            EventRing,
            w64.MMIO_PAGE_SIZE,
            controller_arena,
        );

        event_trb_ring = event_trb_ring_allocation_result.data;

        var ring: TransferRequestBlockRing = undefined;
        initialize_trb_ring(&ring, event_trb_ring_allocation_result.physical_address_start, false);
        //we are overloading the TransferRequestBlock struct here since it is the same layout as an Event Ring Segment Table Entry
        const event_ring_segment_entry = TransferRequestBlock{
            .data_pointer = event_trb_ring_allocation_result.physical_address_start,
            .status = event_trb_ring.ring.ring.len, //really the length of the ring
            .control = 0, //reserved
        };

        event_trb_ring.* = .{
            .ring = ring,
            .event_ring_segment_entry = event_ring_segment_entry,
            .erdp = &interrupter_registers.erdp,
            .event_trb_ring_physical_address = event_trb_ring_allocation_result.physical_address_start,
        };

        const install_result = pcie.install_interrupt_hander(pcie_device, kernel.xhci_interrupt_handler);
        if (!install_result.success) {
            toolbox.panic("Failed to install interrupt!!!", .{});
            //TODO log error
        }
        interrupt_vector = install_result.vector;

        interrupter_registers.* = .{
            .iman = .{ .ie = true }, //enable interrupts
            .imod = .{
                .imodi = 4000,
                .imodc = 4000,
            },
            .erstsz = 1, //Only 1 Event Ring Segment Table Entry
            .erdp = .{
                .erdp = @intCast(event_trb_ring_allocation_result.physical_address_start >> 4),
                .ehb = 0,
            },
            .erstba = .{
                .base_address = @intCast(
                    (event_trb_ring_allocation_result.physical_address_start +
                        @offsetOf(
                        EventRing,
                        "event_ring_segment_entry",
                    )) >> 6,
                ),
            },
        };

        //TODO: xhci does not start up on old desktop.  but will start if erstdba is not set
        //@fence(.SeqCst);
        //println_serial("interrupter_registers.erstsz: {x}", .{interrupter_registers.erstsz});
        //println_serial("interrupter_registers.erdp: {x}", .{interrupter_registers.erdp});
        //println_serial("interrupter_registers.erstba: {x}", .{interrupter_registers.erstba});
        //println_serial("event_trb_ring.event_ring_segment_entry: {x}", .{event_trb_ring.event_ring_segment_entry});
    }

    //set up device slots (but don't enable them, yet)
    var device_slots: []DeviceContextPointer = undefined;
    {
        const device_slots_allocation_result = alloc_slice_aligned(
            DeviceContextPointer,
            hcsparams1.max_device_slots + 1,
            w64.MMIO_PAGE_SIZE,
            controller_arena,
        );
        device_slots = device_slots_allocation_result.data;
        const hcsparams2 = capability_registers.read_register(CapabilityRegisters.StructuralParameters2);
        const number_of_scratch_pad_buffers =
            (@as(u64, hcsparams2.max_scratchpad_buffers_hi) << 5) |
            @as(u64, hcsparams2.max_scratchpad_buffers_lo);

        if (number_of_scratch_pad_buffers > 0) {
            echo_line("Creating {} scratch pad buffers for xHCI controller...", .{number_of_scratch_pad_buffers});
            const scratch_pad_buffer_pointer_array_allocation_result = alloc_slice_aligned(
                ScratchPadBufferPointer,
                number_of_scratch_pad_buffers,
                w64.MMIO_PAGE_SIZE,
                controller_arena,
            );
            const scratch_pad_buffers_allocation_result = alloc_slice_aligned(
                u8,
                w64.MMIO_PAGE_SIZE * number_of_scratch_pad_buffers,
                w64.MMIO_PAGE_SIZE,
                controller_arena,
            );
            const scratch_pad_buffer_pointer_array = scratch_pad_buffer_pointer_array_allocation_result.data;
            for (scratch_pad_buffer_pointer_array, 0..) |*spbp, i| {
                spbp.* = scratch_pad_buffers_allocation_result.physical_address_start + i * w64.MMIO_PAGE_SIZE; //@ptrToInt(&scratch_pad_buffers[i * kernel.PHYSICAL_PAGE_SIZE]);
            }

            device_slots[0] = scratch_pad_buffer_pointer_array_allocation_result.physical_address_start;
            echo_line("Done!", .{});
        } else {
            echo_line("No scratch pad buffers for xHCI controller!", .{});
        }
        operational_registers.write_device_context_base_address_array_pointer(
            device_slots_allocation_result.physical_address_start,
        );
    }

    //Start controller!
    {
        var command = operational_registers
            .read_register(OperationalRegisters.USBCommand);
        command.interrupter_enable = true; //false;
        command.run_stop = true;
        operational_registers.write_register(command);

        //TODO: xhci does not start up on old desktop.  but will start if erstdba is not set
        //{
        //const preboot_console = @import("../preboot_console.zig");
        //preboot_console.clear();
        //while (true) {
        //println_serial("status: {x}", .{event_trb_ring.ring.ring[0]});
        ////asm volatile ("pause");
        //}
        //}

        echo_line("xHCI controller started!", .{});
    }

    //check if there was an error starting it up
    {
        const status = operational_registers.read_register(OperationalRegisters.USBStatus);
        if (status.host_controller_error) {
            echo_line("Status: {}", .{status});
            return error.ErrorStartingXHCIController;
        }
    }

    //TODO set up a USB hub object to represent the root hub
    //A usb hub contains ports and other information including the global reset lock

    const hash_map_arena = controller_arena.create_arena_from_arena(toolbox.kb(32));
    const root_hub_usb_ports = bar_to_slice(
        PortRegisters,
        bar0,
        @as(usize, capability_registers.length) + 0x400,
        hcsparams1.max_ports,
    );
    const controller = controller_arena.push(Controller);
    controller.* = .{
        .pcie_descriptor = pcie_device,
        .arena = controller_arena,
        .capability_registers = capability_registers,
        .interrupter_registers = interrupter_registers,
        .operational_registers = operational_registers,

        .event_response_map_arena = hash_map_arena,
        .event_response_map = toolbox.HashMap(usize, PollEventRingResult).init(TransferRequestBlockRing.RING_SIZE, hash_map_arena),
        .doorbells = doorbells,
        .command_ring = command_trb_ring,
        .event_ring = event_trb_ring,
        .device_slots = device_slots,

        .interrupt_vector = interrupt_vector,

        .root_hub_usb_ports = root_hub_usb_ports,

        .devices = toolbox.RandomRemovalLinkedList(*Device).init(controller_arena),
    };

    for (0..root_hub_usb_ports.len) |port_index| {
        const device_opt = init_device(
            port_index,
            controller,
        ) catch |e| {
            echo_line("Error initializing device! {}", .{e});
            continue;
        };
        if (device_opt) |device| {
            _ = controller.devices.append(device);
        }
    } //end port loop

    return controller;
}
pub fn send_end_of_interrupt(controller: *Controller) void {
    var status =
        controller.operational_registers.read_register(OperationalRegisters.USBStatus);
    status.event_interrupt = true;
    status.port_change_detect = true;
    controller.operational_registers.write_register(status);
    controller.interrupter_registers.iman = controller.interrupter_registers.iman;
    _ = controller.interrupter_registers.iman;
    //.{ .ie = true };
}
fn bar_to_register(comptime Register: type, bar: pcie.BaseAddressRegisterData, offset: usize) *volatile Register {
    return @ptrCast(@alignCast(bar[offset .. offset + @sizeOf(Register)].ptr));
}
fn bar_to_slice(
    comptime ChildType: type,
    bar: pcie.BaseAddressRegisterData,
    offset: usize,
    len: usize,
) []volatile ChildType {
    const slice = @as(
        [*]volatile ChildType,
        @ptrCast(@alignCast(bar[offset .. offset + @sizeOf(ChildType) * len].ptr)),
    )[0..len];
    return slice;
}

//TODO: change to error log system
fn init_device(
    port_index: usize,
    controller: *Controller,
) !?*Device {
    const port_number = port_index + 1;
    const port_registers = &controller.root_hub_usb_ports[port_index];
    const doorbells = controller.doorbells;
    const device_slots = controller.device_slots;
    var portsc = port_registers.read_register(PortRegisters.StatusAndControlRegister);
    //TODO SeaBIOS seems to create a usb device object per port?
    //     not sure we want that

    {
        profiler.begin("Detect xHCI port");
        defer profiler.end();

        const timeout_ms = 10;
        const deadline_ms = toolbox.now().milliseconds() + timeout_ms;
        while (true) {
            if (portsc.current_connect_status) {
                break;
            }
            if (toolbox.now().milliseconds() >= deadline_ms) {
                echo_line("No device on port {}", .{port_number});
                return null;
            }
            portsc = port_registers.read_register(PortRegisters.StatusAndControlRegister);
            std.atomic.spinLoopHint();
        }
    }
    var device_arena = toolbox.Arena.init(toolbox.mb(2));
    errdefer device_arena.free_all();

    const device = device_arena.push(Device);
    //TODO run thread for each port

    //TODO take reset lock

    //reset the port
    switch (portsc.port_link_state) {

        //TODO
        .U0 => {
            // A USB3 port - controller automatically performs reset
            // Do nothing
        },
        .Polling => {
            // A USB2 port - perform device reset
            portsc.port_reset = true;
            port_registers.write_register(portsc);
        },
        else => {
            echo_line("Unexpected state for USB device!", .{});

            //TODO report error and give up on port
            return error.UnexpectedStateForUSBDevice;
        },
    }

    //wait for reset
    {
        profiler.begin("Wait xHCI device reset");
        defer profiler.end();

        const timeout_ms = 1000;
        const deadline_ms = toolbox.now().milliseconds() + timeout_ms;
        while (true) {
            if (portsc.port_enabled_disabled) {
                //reset done!
                echo_line("USB device deteced on port {}! Port Speed: {}", .{ port_number, portsc.port_speed });
                break;
            }
            if (!portsc.current_connect_status) {
                //TODO report error and give up on port
                return error.UnknownErrorWaitingUSBPortToReset;
            }
            if (toolbox.now().milliseconds() >= deadline_ms) {
                echo_line("Failed to reset USB port", .{});
                //TODO report error and give up on port
                return error.TimedOutWaitingUSBPortToReset;
            }
            portsc = port_registers.read_register(PortRegisters.StatusAndControlRegister);
            std.atomic.spinLoopHint();
        }
    }
    switch (portsc.port_speed) {
        .FullSpeed, .LowSpeed, .HighSpeed, .SuperSpeed => {},
        else => return error.InvalidSpeedOnUSBPort,
    }

    //4.After the port successfully reaches the Enabled state, system software shall obtain a Device Slot for the newly attached device using an Enable Slot Command, as described in section 4.3.2.
    var slot_id: u8 = 0;
    {
        const command_response = submit_command(.{
            .data_pointer = 0,
            .status = 0,
            //TODO get slot type and OR into control
            .control = @as(u32, @intFromEnum(TransferRequestBlock.Type.EnableSlotCommand)) << 10,
        }, controller) catch |e| {
            echo_line("Error enabling slot: {}", .{e});
            return e;
        };
        if (command_response.number_of_bytes_not_transferred != 0) {
            echo_line("Error enabling slot, due to short packet", .{});
            return error.ShortPacketError;
        }

        //TODO bitcast to EventTRB?
        slot_id = command_response.trb.read_slot_id();
    }

    //5. After successfully obtaining a Device Slot, system software shall initialize the data structures associated with the slot as described in section 4.3.3.
    var device_slot_data_structures: DeviceSlotDataStructures = undefined;
    {
        const hccparams1 = controller.capability_registers.read_register(CapabilityRegisters.HCCPARAMS1);
        const uses_64byte_contexts = hccparams1.csz;
        if (uses_64byte_contexts) {
            device_slot_data_structures = try initialize_device_slot_data_structures(
                64 / 4,
                port_number,
                portsc.port_speed,
                slot_id,
                device_slots,
                &doorbells[slot_id],
                device_arena,
            );
        } else {
            device_slot_data_structures = try initialize_device_slot_data_structures(
                32 / 4,
                port_number,
                portsc.port_speed,
                slot_id,
                device_slots,
                &doorbells[slot_id],
                device_arena,
            );
        }
    }
    //6. Once the slot related data structures are initialized, system software shall use an Address Device Command to assign an address to the device and enable its Default Control Endpoint, as described in section 4.3.4.
    {
        const command = TransferRequestBlock{
            .data_pointer = device_slot_data_structures.input_context.physical_address,
            .status = 0,
            //TODO get slot type and OR into control
            .control = @as(u32, slot_id) << 24 | @as(u32, @intFromEnum(TransferRequestBlock.Type.AddressDeviceCommand)) << 10,
        };
        //TODO verify no error from submit command.  verify output context is addressed
        _ = submit_command(command, controller) catch |e| {
            echo_line("Error setting input context: {}", .{e});
            return e;
        };
    }

    //TODO unlock reset lock

    //7) For LS, HS, and SS devices; 8, 64, and 512 bytes, respectively, are the only packet sizes allowed for the Default Control Endpoint, so step a may be skipped.
    //For FS devices, system software should initially read the first 8 bytes of the USB Device Descriptor to retrieve the value of the bMaxPacketSize0 field and determine the actual Max Packet Size for the Default Control Endpoint, by issuing a USB GET_DESCRIPTOR request to the device, update the Default Control Endpoint Context with the actual Max Packet Size and inform the xHC of the context change. Step a describes this operation.
    //This is done in step 8.

    //8. Now that the Default Control Endpoint is fully operational, system software may read the complete USB Device Descriptor and possibly the Configuration Descriptors so that it can hand the device off to the appropriate Class Driver(s). To read the USB descriptors, software will issue USB GET_DESCRIPTOR requests through the devices’ Default Control Endpoint.
    const endpoint_0_transfer_ring = device_slot_data_structures.endpoint_0_transfer_ring;

    //Get Device Descriptor
    const device_descriptor_result = alloc_object(
        USBDeviceDescriptor,
        controller.arena,
    );
    const device_descriptor = device_descriptor_result.data;
    const device_descriptor_physical_address = device_descriptor_result.physical_address_start;
    {
        get_descriptor_from_endpoint0(
            device_descriptor_physical_address,
            8, // only read first 8 bytes to get max packet
            .Device,
            0,
            .Device,
            0,
            device_slot_data_structures.endpoint_0_transfer_ring,
            controller,
        ) catch |e| {
            echo_line("Error getting device descriptor: {}", .{e});
            return e;
        };

        //set max packet if different
        {
            if (portsc.port_speed == .FullSpeed) {
                const input_context = device_slot_data_structures.input_context;
                const control_endpoint_context = get_endpoint_context_from_input_context(1, input_context);
                const input_control_context = get_input_control_context_from_input_context(input_context);
                const old_max_packet = control_endpoint_context.max_packet_size;
                const max_packet: u16 = if (device_descriptor.usb_version < 0x300)
                    @as(u16, device_descriptor.max_packet_size)
                else
                    @as(u16, 1) << @as(u4, @intCast(device_descriptor.max_packet_size));
                control_endpoint_context.max_packet_size = max_packet;

                input_control_context.add_context_flags = 1 << 1; //endpoint 0 context
                input_control_context.drop_context_flags = 0;

                const command = TransferRequestBlock{
                    .data_pointer = input_context.physical_address,
                    .status = 0,

                    .control = @as(u32, slot_id) << 24 | @as(u32, @intFromEnum(TransferRequestBlock.Type.EvaluateContextCommand)) << 10,
                };
                _ = submit_command(command, controller) catch |e| {
                    echo_line("Error setting max packet on input context: {}", .{e});
                    return e;
                };

                const output_device_context = device_slot_data_structures.output_device_context;
                const output_control_endpoint_context = get_endpoint_context_from_output_device_context(1, output_device_context);

                echo_line("old packet size: {}, new packet size: {}", .{ old_max_packet, output_control_endpoint_context.max_packet_size });
            }
        }
    }
    get_descriptor_from_endpoint0(
        device_descriptor_physical_address,
        @sizeOf(USBDeviceDescriptor),
        .Device,
        0,
        .Device,
        0,
        device_slot_data_structures.endpoint_0_transfer_ring,
        controller,
    ) catch |e| {
        echo_line("Error getting device descriptor: {}", .{e});
        return e;
    };

    //Get manufacturer string
    var manufacturer_string: ?[]const u8 = null;
    if (device_descriptor.manufacturer_index > 0) {
        manufacturer_string = try get_string_descriptor(
            device_descriptor.manufacturer_index,
            endpoint_0_transfer_ring,
            controller,
            device_arena,
        );
    }
    //Get product string
    var product_string: ?[]const u8 = null;
    if (device_descriptor.product_index > 0) {
        product_string = try get_string_descriptor(
            device_descriptor.product_index,
            endpoint_0_transfer_ring,
            controller,
            device_arena,
        );
    }
    //Get serial number string
    var serial_number_string: ?[]const u8 = null;
    if (device_descriptor.serial_number_index > 0) {
        serial_number_string = try get_string_descriptor(
            device_descriptor.serial_number_index,
            endpoint_0_transfer_ring,
            controller,
            device_arena,
        );
    }

    //Get Config Descriptor
    var configuration_and_interface_descriptor: []u8 = undefined;
    var interfaces: []Interface = undefined;
    var interface_index: usize = 0;
    var endpoint_index: usize = 0;
    {
        const scratch_arena = w64.get_scratch_arena();
        scratch_arena.save();
        defer scratch_arena.restore();

        const input_context = device_slot_data_structures.input_context;
        const input_control_context = get_input_control_context_from_input_context(input_context);
        //const output_device_context = device_slot_data_structures.output_device_context;

        const configuration_descriptor_result = alloc_object(
            USBConfigurationDescriptor,
            scratch_arena,
        );
        const configuration_descriptor = configuration_descriptor_result.data;
        const configuration_descriptor_physical_address = configuration_descriptor_result.physical_address_start;
        get_descriptor_from_endpoint0(
            configuration_descriptor_physical_address,
            @sizeOf(USBConfigurationDescriptor),
            .Device,
            0,
            .Configuration,
            0,
            device_slot_data_structures.endpoint_0_transfer_ring,
            controller,
        ) catch |e| {
            echo_line("Error getting config descriptor: {}", .{e});
            return e;
        };
        const configuration_and_interface_descriptor_result = alloc_slice(
            u8,
            configuration_descriptor.total_length,
            device_arena,
        );
        configuration_and_interface_descriptor = configuration_and_interface_descriptor_result.data;
        const configuration_and_interface_descriptor_physical_address = configuration_and_interface_descriptor_result.physical_address_start;
        for (configuration_and_interface_descriptor) |*b| b.* = 0;
        get_descriptor_from_endpoint0(
            configuration_and_interface_descriptor_physical_address,
            @as(u16, @intCast(configuration_and_interface_descriptor.len)),
            .Device,
            0,
            .Configuration,
            0,
            device_slot_data_structures.endpoint_0_transfer_ring,
            controller,
        ) catch |e| {
            echo_line("Error getting full config descriptor: {}", .{e});
            return e;
        };
        //TODO set configuration for endpoint

        echo_line("Device {?s} (Serial Number: {?s}) by {?s} has {} interfaces and {} configs", .{ product_string, serial_number_string, manufacturer_string, configuration_descriptor.num_interfaces, device_descriptor.num_configurations });

        //TODO store configuration descriptors in a list and retrieve them with a generic function that takes in a descriptor struct type?
        if (configuration_descriptor.num_interfaces <= 0) {
            //free all data structures associated with this device since this seems to be a useless device
            device_arena.free_all();
            return null;
        }
        var max_device_context_index: u5 = 0;
        var i: usize = 0;

        interfaces = device_arena.push_slice(Interface, configuration_descriptor.num_interfaces);
        var current_interface: *Interface = undefined;
        var endpoints: []Endpoint = undefined;
        var current_endpoint: *Endpoint = undefined;
        const after_first_interface = false;
        while (i < configuration_and_interface_descriptor.len) {
            const length = configuration_and_interface_descriptor[i];
            const descriptor_type = configuration_and_interface_descriptor[i + 1];
            if (length == 0) {
                echo_line("Zero length descriptor, aborting enumerating this device...", .{});
                break;
            }
            defer i += length;
            switch (descriptor_type) {
                @intFromEnum(DescriptorType.Interface) => {
                    if (interface_index >= interfaces.len) {
                        //TODO figure out why this happens on my desktop
                        continue;
                    }
                    const interface_descriptor = @as(
                        *USBInterfaceDescriptor,
                        @ptrCast(configuration_and_interface_descriptor.ptr + i),
                    );
                    echo_line("    {} interface {}, setting {} with {} endpoints", .{ interface_descriptor.interface_class, interface_descriptor.interface_number, interface_descriptor.alternate_setting, interface_descriptor.num_endpoints });

                    //TODO
                    const class_data: Interface.ClassData = switch (interface_descriptor.interface_class) {
                        .HID => .{ .HID = .{ .hid_descriptor = undefined } },

                        .Audio => .Audio,
                        .CommunicationsAndCDCControl => .CommunicationsAndCDCControl,
                        .Physical => .Physical,
                        .Image => .Image,
                        .Printer => .Printer,
                        .MassStorage => .MassStorage,
                        .Hub => .Hub,
                        .CDCData => .CDCData,
                        .SmartCard => .SmartCard,
                        .ContentSecurity => .ContentSecurity,
                        .Video => .Video,
                        .PersonalHealthcare => .PersonalHealthcare,
                        .AudioVideoDevices => .AudioVideoDevices,
                        .BillboardDevice => .BillboardDevice,
                        .USBTypeCBridge => .USBTypeCBridge,
                        .DiagnosticDevice => .DiagnosticDevice,
                        .WirelessController => .WirelessController,
                        .Miscellaneous => .Miscellaneous,
                        .ApplicationSpecific => .ApplicationSpecific,
                        .VendorSpecific => .VendorSpecific,

                        _ => {
                            interface_index -= 1;
                            //bad interface
                            continue;
                        },
                    };
                    //finalize previous interface
                    if (after_first_interface) {
                        current_interface.number_of_unsupported_endpoints = endpoints.len - endpoint_index;
                        current_interface.endpoints = endpoints[0..endpoint_index];
                    }

                    endpoints = device_arena.push_slice(Endpoint, interface_descriptor.num_endpoints);

                    current_interface = &interfaces[interface_index];
                    interface_index += 1;

                    current_interface.* = .{
                        .parent_device = device,
                        .class_data = class_data,
                        .interface_number = interface_descriptor.interface_number,
                        .endpoints = endpoints,
                        .number_of_unsupported_endpoints = 0,
                    };
                },
                @intFromEnum(DescriptorType.Endpoint) => {
                    if (endpoint_index >= endpoints.len) {
                        //TODO figure out why this happens on my desktop
                        continue;
                    }
                    const endpoint_descriptor = @as(
                        *align(1) USBEndpointDescriptor,
                        @ptrCast(configuration_and_interface_descriptor.ptr + i),
                    );

                    if (endpoint_descriptor.transfer_type() != .Interrupt) {
                        //TODO support Bulk and Isochronous endpoints
                        //println_serial("    Endpoint {x}, direction: {}, Transfer type: {} -- Currently unsupported", .{
                        //endpoint_descriptor.endpoint_number(),
                        //endpoint_descriptor.direction(),
                        //endpoint_descriptor.transfer_type(),
                        //});
                        continue;
                    }

                    //TODO configure endpoint
                    {
                        const endpoint_number_usize = @as(usize, endpoint_descriptor.endpoint_number());
                        const in_or_out_offset: usize = switch (endpoint_descriptor.direction()) {
                            .Out => @as(usize, 0),
                            .In => @as(usize, 1),
                        };
                        const device_context_index = endpoint_number_usize * 2 + in_or_out_offset;
                        var endpoint_context = get_endpoint_context_from_input_context(
                            device_context_index,
                            input_context,
                        );

                        endpoint_context.* = std.mem.zeroes(EndpointContext);

                        //TODO this will be true regardless because we only support Interrupt transfer type now
                        if (endpoint_descriptor.transfer_type() == .Interrupt) {
                            endpoint_context.interval = endpoint_descriptor.interval;
                        }
                        endpoint_context.transfer_type = endpoint_descriptor.transfer_type();
                        endpoint_context.is_control_or_input_endpoint = endpoint_descriptor.direction() == .In;

                        endpoint_context.cerr = 3;
                        endpoint_context.max_packet_size = endpoint_descriptor.max_packet_size;
                        endpoint_context.average_trb_length = endpoint_descriptor.max_packet_size;
                        //TODO: this is wrong if maximum burst is non-zero
                        endpoint_context.max_esit_payload_lo = endpoint_descriptor.max_packet_size;
                        var endpoint_transfer_ring: *TransferRing = undefined;
                        var endpoint_transfer_ring_physical_address: u64 = 0;
                        {
                            const transfer_trb_ring_allocation_result = alloc_object_aligned(
                                TransferRing,
                                w64.MMIO_PAGE_SIZE,
                                device_arena,
                            );
                            endpoint_transfer_ring = transfer_trb_ring_allocation_result.data;

                            var trb_ring: TransferRequestBlockRing = undefined;
                            initialize_trb_ring(&trb_ring, transfer_trb_ring_allocation_result.physical_address_start, true);
                            endpoint_transfer_ring.* = .{
                                .trb_ring = trb_ring,
                                .doorbell = &doorbells[slot_id],
                            };
                            endpoint_transfer_ring_physical_address = transfer_trb_ring_allocation_result.physical_address_start;
                        }
                        endpoint_context.tr_dequeue_pointer = @as(u60, @intCast(endpoint_transfer_ring_physical_address >> 4));
                        endpoint_context.dcs = 1;

                        const endpoint_context_index = endpoint_descriptor.endpoint_number() * 2 + (if (endpoint_descriptor.direction() == .In) @as(u4, 1) else @as(u4, 0));
                        input_control_context.add_context_flags |= @as(u32, 1) << endpoint_context_index;
                        max_device_context_index = @max(endpoint_context_index, max_device_context_index);

                        current_endpoint = &endpoints[endpoint_index];
                        endpoint_index += 1;
                        current_endpoint.* = Endpoint{
                            .parent_interface = current_interface,
                            .doorbell_value = @as(u32, endpoint_context_index),
                            .transfer_ring = endpoint_transfer_ring,
                            .endpoint_number = endpoint_descriptor.endpoint_number(),
                            .direction = endpoint_descriptor.direction(),
                            .transfer_type = endpoint_descriptor.transfer_type(),
                            .endpoint_context = endpoint_context,
                        };
                    }
                },
                @intFromEnum(DescriptorType.HID) => {
                    const hid_descriptor = @as(
                        *align(1) usb_hid.Descriptor,
                        @ptrCast(configuration_and_interface_descriptor.ptr + i),
                    );
                    current_interface.class_data = .{ .HID = .{ .hid_descriptor = hid_descriptor.* } };
                },
                @intFromEnum(DescriptorType.Configuration) => {},
                else => {
                    //println_serial("    Unknown descriptor: type: {x}, length: {}", .{ descriptor_type, length });
                },
            }
        } //end  while (i < configuration_and_interface_descriptor.len)

        if (endpoint_index > endpoints.len) {
            //TODO figure out why this happens! Maybe we get the wrong length on my desktop?
            endpoint_index = endpoints.len;
        }
        //finalize previous interface
        current_interface.number_of_unsupported_endpoints = endpoints.len - endpoint_index;
        current_interface.endpoints = endpoints[0..endpoint_index];

        input_control_context.drop_context_flags = 0;

        {
            var slot_context = get_slot_context_from_input_context(input_context);
            slot_context.context_entries = max_device_context_index + 1;
        }

        {
            input_control_context.add_context_flags |= 1 << 0; //enable slot context

            //remove ep0 context since it is already configured
            input_control_context.add_context_flags &= ~(@as(u32, 1) << 1); //enable slot context

        }
        const command = TransferRequestBlock{
            .data_pointer = input_context.physical_address,
            .status = 0,
            .control = @as(u32, slot_id) << 24 | @as(u32, @intFromEnum(TransferRequestBlock.Type.ConfigureEndpointCommand)) << 10,
        };
        _ = submit_command(
            command,
            controller,
        ) catch |e| {
            echo_line("Error running Configure Endpoint Command: {}", .{e});
            return e;
        };
        echo_line("Successfully ran Configure Endpoint Command!", .{});

        set_configuration_on_endpoint0(
            configuration_descriptor.configuration_value,
            device_slot_data_structures.endpoint_0_transfer_ring,
            controller,
        ) catch |e| {
            echo_line("Error running SET_CONFIGURATION: {}", .{e});
            return e;
        };
        echo_line("Successfully ran SET_CONFIGURATION!", .{});

        //TODO send SET_FEATURE for remote wake up and others if supported

    } //end Get Config Descriptor
    device.* = .{
        .parent_controller = controller,
        .is_connected = true,
        .manufacturer = manufacturer_string,
        .product = product_string,
        .port_id = port_number,
        .serial_number = serial_number_string,
        .port_registers = port_registers,
        .arena = device_arena,
        .input_context = device_slot_data_structures.input_context,
        .output_device_context = device_slot_data_structures.output_device_context,
        .descriptor_data = configuration_and_interface_descriptor,
        .interfaces = interfaces[0..interface_index],
        .endpoint_0_transfer_ring = device_slot_data_structures.endpoint_0_transfer_ring,
        .number_of_unsupported_interfaces = interfaces.len - interface_index,
        .hid_devices = toolbox.RandomRemovalLinkedList(usb_hid.USBHIDDevice).init(device_arena),
    };
    return device;
}
threadlocal var example_tls_var: usize = 0;
fn get_string_descriptor(
    string_descriptor_index: u8,
    endpoint_0_transfer_ring: *volatile TransferRing,
    controller: *Controller,
    device_arena: *toolbox.Arena,
) ![]const u8 {
    const scratch_arena = w64.get_scratch_arena();
    echo_line("Arena: address: {X}, TLS var address: {X}", .{
        @intFromPtr(scratch_arena),
        @intFromPtr(&example_tls_var),
    });
    scratch_arena.save();
    defer scratch_arena.restore();

    const descriptor_header_result = alloc_object(
        USBDescriptorHeader,
        scratch_arena,
    );
    const descriptor_header = descriptor_header_result.data;
    const descriptor_header_physical_address = descriptor_header_result.physical_address_start;
    get_descriptor_from_endpoint0(
        descriptor_header_physical_address,
        @sizeOf(USBDescriptorHeader),
        .Device,
        string_descriptor_index,
        .String,
        0x0409, //US-English
        endpoint_0_transfer_ring,
        controller,
    ) catch |e| {
        echo_line("Failed to get string descriptor header: {}", .{e});
    };
    const string_descriptor_result = alloc_slice(
        u8,
        descriptor_header.length,
        device_arena,
    );
    const string_descriptor = string_descriptor_result.data;
    const string_descriptor_physical_address = string_descriptor_result.physical_address_start;

    for (string_descriptor) |*c| c.* = 0;
    get_descriptor_from_endpoint0(
        string_descriptor_physical_address,
        descriptor_header.length,
        .Device,
        string_descriptor_index,
        .String,
        0x0409, //US-English
        endpoint_0_transfer_ring,
        controller,
    ) catch |e| {
        echo_line("Failed to get string descriptor: {}", .{e});
    };
    return string_descriptor[@sizeOf(USBDescriptorHeader)..];
}

fn get_input_control_context_from_input_context(input_context: InputContext) *volatile InputControlContext {
    return toolbox.ptr_cast(*volatile InputControlContext, &input_context.data[0]);
}
fn get_slot_context_from_input_context(
    input_context: InputContext,
) *volatile SlotContext {
    //slot context is device context index (DCI) 0 in the input context
    return @as(*volatile SlotContext, @ptrCast(get_endpoint_context_from_input_context(0, input_context)));
}
fn get_endpoint_context_from_input_context(
    device_context_index: usize,
    input_context: InputContext,
) *volatile EndpointContext {
    const endpoint_context_word_index = (1 + device_context_index) * input_context.context_size_in_words;
    return toolbox.ptr_cast(*volatile EndpointContext, &input_context.data[endpoint_context_word_index]);
}
fn get_endpoint_context_from_output_device_context(
    device_context_index: usize,
    output_device_context: DeviceContext,
) *volatile EndpointContext {
    const endpoint_context_word_index = device_context_index * output_device_context.context_size_in_words;
    return toolbox.ptr_cast(*volatile EndpointContext, &output_device_context.data[endpoint_context_word_index]);
}

const DescriptorReceipient = enum {
    Device,
    Interface,
    Endpoint,
    Other,
};

pub fn get_descriptor_from_endpoint0(
    destination_buffer_physical_address: u64,
    length: u16,
    recipient: DescriptorReceipient,
    descriptor_index: u8,
    descriptor_type: DescriptorType,
    flags: u16,
    endpoint_0_transfer_ring: *volatile TransferRing,
    controller: *Controller,
) !void {
    try send_setup_command_endpoint0(
        6,
        .DeviceToHost,
        .Standard,
        recipient, //.Device,
        destination_buffer_physical_address,
        length,
        (@as(u16, @intFromEnum(descriptor_type)) << 8) | @as(u16, descriptor_index),
        flags,
        endpoint_0_transfer_ring,
        controller,
    );
}
fn get_configuration_from_endpoint0(
    endpoint_0_transfer_ring: *volatile TransferRing,
    event_trb_ring: *volatile EventRing,
) !u8 {
    var ret: u8 = 0;
    try send_setup_command_endpoint0(
        8,
        .DeviceToHost,
        .Standard,
        .Device,
        &ret,
        1,
        0,
        0,
        endpoint_0_transfer_ring,
        event_trb_ring,
    );

    return ret;
}
fn set_configuration_on_endpoint0(
    configuration_value: u8,
    endpoint_0_transfer_ring: *volatile TransferRing,
    controller: *Controller,
) !void {
    try send_setup_command_endpoint0(
        9,
        .HostToDevice,
        .Standard,
        .Device,
        null,
        0,
        configuration_value,
        0,
        endpoint_0_transfer_ring,
        controller,
    );
}
pub fn send_setup_command_endpoint0(
    request: u8,
    direction: enum { HostToDevice, DeviceToHost },
    request_type: enum { Standard, Class, Vendor, Reserved },
    recipient: DescriptorReceipient,
    destination_buffer_physical_address_opt: ?u64,
    length: u16,
    value: u16,
    index: u16,
    endpoint_0_transfer_ring: *volatile TransferRing,
    controller: *Controller,
) !void {
    const bm_request_type: u8 = (@as(u8, @intFromEnum(direction)) << 7) | (@as(u8, @intFromEnum(request_type)) << 5) | @as(u8, @intFromEnum(recipient));
    const setup_stage_trb = SetupStageTRB{
        .bm_request_type = bm_request_type,
        .b_request = request,
        .w_value = value,
        .w_index = index,
        .w_length = length,
        .trb_transfer_length = 8,
        .reserved0 = 0,
        .interrupter_target = 0,
        .cycle_bit = 0,
        .reserved1 = 0,
        .ioc = false,
        .idt = true,
        .reserved2 = 0,
        .trb_type = 2,
        .trt = b: {
            if (length == 0) {
                break :b .NoDataStage;
            } else if (direction == .HostToDevice) {
                break :b .OutDataStage;
            } else {
                break :b .InDataStage;
            }
        },
    };
    //TODO factor into function called queue trb
    {
        const trb_to_store = @as(TransferRequestBlock, @bitCast(setup_stage_trb));
        var trb = &endpoint_0_transfer_ring.trb_ring.ring[endpoint_0_transfer_ring.trb_ring.index];
        trb.* = trb_to_store;
        trb.write_cycle_bit(endpoint_0_transfer_ring.trb_ring.cs);
        endpoint_0_transfer_ring.trb_ring.index += 1;
        if (endpoint_0_transfer_ring.trb_ring.index >= endpoint_0_transfer_ring.trb_ring.ring.len - 1) {
            //reached the link TRB, now wrap back to the beginning
            endpoint_0_transfer_ring.trb_ring.cs ^= 1;
            endpoint_0_transfer_ring.trb_ring.ring[endpoint_0_transfer_ring.trb_ring.index].write_cycle_bit(endpoint_0_transfer_ring.trb_ring.cs);
            endpoint_0_transfer_ring.trb_ring.index = 0;
        }
    }
    if (destination_buffer_physical_address_opt) |destination_buffer_physical_address| {
        const data_stage_trb = DataStageTRB{
            .data_buffer_address = destination_buffer_physical_address,
            .trb_transfer_length = length,
            .td_size = 0, //number of packets left
            .interrupter_target = 0,
            .cycle_bit = 0,
            .ent = false, //evaluate next trb
            .isp = true, //interrupt on short packet
            .ns = false, //no snoop
            .ch = 0, //chain bit
            .ioc = false, //interrupt on completion
            .idt = false, //immediate data
            .reserved1 = 0,
            .trb_type = 3,
            .dir = .DeviceToHost, //direction
            .reserved4 = 0,
        };
        //TODO factor into function called queue trb
        {
            //TODO split each trb into max packet
            const trb_to_store = @as(TransferRequestBlock, @bitCast(data_stage_trb));
            var trb = &endpoint_0_transfer_ring.trb_ring.ring[endpoint_0_transfer_ring.trb_ring.index];
            trb.* = trb_to_store;
            trb.write_cycle_bit(endpoint_0_transfer_ring.trb_ring.cs);
            endpoint_0_transfer_ring.trb_ring.index += 1;
            if (endpoint_0_transfer_ring.trb_ring.index >= endpoint_0_transfer_ring.trb_ring.ring.len - 1) {
                //reached the link TRB, now wrap back to the beginning
                endpoint_0_transfer_ring.trb_ring.cs ^= 1;
                endpoint_0_transfer_ring.trb_ring.ring[endpoint_0_transfer_ring.trb_ring.index].write_cycle_bit(endpoint_0_transfer_ring.trb_ring.cs);
                endpoint_0_transfer_ring.trb_ring.index = 0;
            }
        }
    }
    const status_stage_trb = StatusStageTRB{
        .reserved1 = 0,
        .interrupter_target = 0,
        .cycle_bit = 0,
        .ent = false,
        .reserved2 = 0,
        .ch = 0, //chain bit
        .ioc = true, //true to generate event TRB
        .reserved3 = 0,
        .trb_type = 4,
        .dir = if (length > 0 and direction == .DeviceToHost) .HostToDevice else .DeviceToHost, //direction (opposite of setup stage)
        .reserved4 = 0,
    };
    //TODO factor into function called queue trb
    const transfer_trb_phyiscal_address: u64 = endpoint_0_transfer_ring.trb_ring.physical_address_of_current_index();
    {
        const trb_to_store = @as(TransferRequestBlock, @bitCast(status_stage_trb));
        var trb = &endpoint_0_transfer_ring.trb_ring.ring[endpoint_0_transfer_ring.trb_ring.index];

        trb.* = trb_to_store;
        trb.write_cycle_bit(endpoint_0_transfer_ring.trb_ring.cs);
        endpoint_0_transfer_ring.trb_ring.index += 1;
        if (endpoint_0_transfer_ring.trb_ring.index >= endpoint_0_transfer_ring.trb_ring.ring.len - 1) {
            //reached the link TRB, now wrap back to the beginning
            endpoint_0_transfer_ring.trb_ring.cs ^= 1;
            endpoint_0_transfer_ring.trb_ring.ring[endpoint_0_transfer_ring.trb_ring.index].write_cycle_bit(endpoint_0_transfer_ring.trb_ring.cs);
            endpoint_0_transfer_ring.trb_ring.index = 0;
        }
    }
    endpoint_0_transfer_ring.doorbell.* = 1;
    _ = try wait_for_transfer_response(transfer_trb_phyiscal_address, controller);
}

//pub fn poll_event_ring_non_blocking(event_trb_ring: *volatile EventRing) !?PollEventRingResult {
//const trb: *volatile TransferRequestBlock = &event_trb_ring.ring.ring[event_trb_ring.ring.index];
//if (trb.read_cycle_bit() == event_trb_ring.ring.cs) {
//event_trb_ring.ring.index += 1;
//if (event_trb_ring.ring.index >= event_trb_ring.ring.ring.len) {
//event_trb_ring.ring.cs ^= 1;
//event_trb_ring.ring.index = 0;
//}
//event_trb_ring.erdp.* = (event_trb_ring.event_trb_ring_physical_address +
//(event_trb_ring.ring.index * @sizeOf(TransferRequestBlock))) | (1 << 3);
//@fence(.SeqCst);

//switch (trb.read_trb_type()) {
//.CommandCompletionEvent,
//.TransferEvent,
//=> {
//if (trb.read_completion_code() != 1) {
//const err = completion_code_to_error(trb.read_completion_code());
//if (err != error.ShortPacketError) {
//return err;
//}
//}

//const ret = PollEventRingResult{
//.trb = trb.*,
//.number_of_bytes_not_transferred = trb.read_number_of_bytes_not_transferred(),
//};
//var pending_request = event_trb_ring.event_response_map.get_or_put(trb.data_pointer, ret);
//utils.assert(pending_request.* != null);
//pending_request.* = ret;
//return ret;
//},
//.PortStatusChangeEvent => {
////TODO
//},
//else => {
//println_serial("Unhandled USB event: {} -- {x}", .{ trb.read_trb_type(), trb });
//},
//}
//}
//return null;
//}
pub fn poll_controller(controller: *Controller, handle_port_change_event: bool) bool {
    const event_trb_ring = controller.event_ring;
    const event_response_map = &controller.event_response_map;
    //TODO
    //const max_retries = 50;
    //var i: usize = 0;
    //while (i < max_retries) : (i += 1) {

    var events_handled: usize = 0;
    var did_transfer_event_occur = false;

    // const controller_status = controller.operational_registers.read_register(OperationalRegisters.USBStatus);
    // for (controller.root_hub_usb_ports, 0..) |port, port_index| {
    //     const portsc = port.read_register(PortRegisters.StatusAndControlRegister);
    //     if (portsc.connect_status_change and !controller_status.hc_halted) {
    //         echo_line("Port change on port id {}, enabled: {}, ccs: {},  csc: {}", .{
    //             port_index + 1,
    //             portsc.current_connect_status,
    //             portsc.port_enabled_disabled,
    //             portsc.connect_status_change,
    //         });
    //         for (event_trb_ring.ring.ring, 0..) |trb, i| {
    //             if (trb.read_trb_type() == .PortStatusChangeEvent) {
    //                 echo_line(
    //                     "Found portsc event at {} for port {}, CS: {}. We are at index {}. Controller CS: {}",
    //                     .{
    //                         i,
    //                         trb.read_port_id(),
    //                         trb.read_cycle_bit(),
    //                         event_trb_ring.ring.index,
    //                         event_trb_ring.ring.cs,
    //                     },
    //                 );
    //             }
    //         }
    //     }
    // }

    while (true) {
        const trb = event_trb_ring.ring.ring[event_trb_ring.ring.index];
        if (trb.read_cycle_bit() != event_trb_ring.ring.cs) {
            break;
        }
        events_handled += 1;
        event_trb_ring.ring.index += 1;
        if (event_trb_ring.ring.index >= event_trb_ring.ring.ring.len) {
            event_trb_ring.ring.cs ^= 1;
            event_trb_ring.ring.index = 0;
        }
        switch (trb.read_trb_type()) {
            .CommandCompletionEvent,
            .TransferEvent,
            => {
                var err_opt: ?anyerror = null;
                // echo_line("Completion code: {}", .{trb.read_completion_code()});
                if (trb.read_completion_code() != 1) {
                    const err = completion_code_to_error(trb.read_completion_code());
                    if (err != error.ShortPacketError) {
                        err_opt = err;
                    }
                }
                const ret = PollEventRingResult{
                    .trb = trb,
                    .number_of_bytes_not_transferred = trb.read_number_of_bytes_not_transferred(),
                    .err = err_opt,
                };
                toolbox.assert(
                    event_response_map.get(trb.data_pointer) == null,
                    "Event ring response should not be full",
                    .{},
                );
                event_response_map.put(trb.data_pointer, ret);
                did_transfer_event_occur = true;
            },
            .PortStatusChangeEvent => {
                handle_port_status_change_event(trb, controller, handle_port_change_event);
            },
            else => {
                echo_line("Unhandled USB event: {} -- {}", .{ trb.read_trb_type(), trb });
            },
        }
    }
    const new_erdp = EventRingDequeuePointer{
        .erdp = @intCast((event_trb_ring.event_trb_ring_physical_address +
            (event_trb_ring.ring.index * @sizeOf(TransferRequestBlock))) >> 4),
        .ehb = 1,
    };
    event_trb_ring.erdp.* = new_erdp;
    @fence(.SeqCst);
    return did_transfer_event_occur;
}

fn handle_port_status_change_event(
    trb: TransferRequestBlock,
    controller: *Controller,
    handle_connect_disconnect: bool,
) void {
    const port_id = trb.read_port_id();
    if (port_id == 0) {
        toolbox.assert(false, "Debug port id was used. We should figure out why...", .{});
        return;
    }
    const port_index = port_id - 1;
    if (port_index < controller.root_hub_usb_ports.len) {
        var port_registers = controller.root_hub_usb_ports[port_index];
        const status_register =
            port_registers.read_register(PortRegisters.StatusAndControlRegister);

        defer port_registers.write_register(status_register);

        echo_line("here!!!!!, port index: {}", .{port_index});
        if (!handle_connect_disconnect) {
            return;
        }
        if (status_register.current_connect_status) {
            //device connected
            const device_opt = init_device(
                port_index,
                controller,
            ) catch |e| b: {
                echo_line("Error initializing device! {}", .{e});
                break :b null;
            };
            echo_line("Device connected!", .{});
            if (device_opt) |device| {
                _ = controller.devices.append(device);
                for (device.interfaces) |*interface| {
                    switch (interface.class_data) {
                        .HID => |hid_data| {
                            usb_hid.init_hid_interface(
                                interface,
                                hid_data.hid_descriptor,
                                w64.get_scratch_arena(),
                            ) catch |e| {
                                //TODO: remove
                                // Required for my desktop keyboard
                                switch (e) {
                                    error.HIDDeviceDoesNotHaveAnInterruptEndpoint, error.ReportIDsNotYetSupported => {},
                                    else => {
                                        toolbox.panic("Error initing HID interface for device {?s}: {}!", .{ device.product, e });
                                    },
                                }
                            };
                        },
                        else => {},
                    }
                }
            }
        } else {
            //device disconnected
            var it = controller.devices.iterator();
            while (it.next()) |device_ptr| {
                const device = device_ptr.*;
                if (device.port_id == port_id) {
                    usb_hid.disconnect(device, controller);

                    controller.devices.remove(device_ptr);
                    device_ptr.*.arena.free_all();
                    echo_line("Device disconnected!", .{});
                    break;
                }
            }
        }
    } else {
        echo_line("Port change event on non-existent port: {}.  Number of ports: {}", .{
            port_id,
            controller.root_hub_usb_ports.len,
        });
    }
}

fn initialize_device_slot_data_structures(
    comptime context_size_in_words: usize,
    port_number: usize,
    port_speed: PortSpeed,
    slot_id: u8,
    device_slots: []DeviceContextPointer,
    doorbell: *volatile u32,
    device_arena: *toolbox.Arena,
) !DeviceSlotDataStructures {
    //1. Allocate an Input Context data structure (6.2.5) and initialize all fields to ‘0’.
    const input_context_allocation_result = alloc_slice_aligned(
        u32,
        context_size_in_words * 33,
        w64.MMIO_PAGE_SIZE,
        device_arena,
    );

    //2. Initialize the Input Control Context (6.2.5.1) of the Input Context by setting the A0 and A1 flags to ‘1’. These flags indicate that the Slot Context and the Endpoint 0 Context of the Input Context are affected by the command.
    const input_context = InputContext{
        .context_size_in_words = context_size_in_words,
        .physical_address = input_context_allocation_result.physical_address_start,
        .data = input_context_allocation_result.data,
    };
    const input_control_context = get_input_control_context_from_input_context(input_context);
    input_control_context.add_context_flags = 1 << 0 | //slot context
        1 << 1; //endpoint 0 context

    //3. Initialize the Input Slot Context data structure (6.2.2).
    //   • Root Hub Port Number = Topology defined.
    //   • Route String = Topology defined. Refer to section 8.9 in the USB3 spec. Note that the Route String does not include the Root Hub Port Number.
    //   • Context Entries = 1.
    {
        const slot_context = get_slot_context_from_input_context(input_context);
        slot_context.route_string_tier_1 = 0;
        slot_context.route_string_tier_2 = 0;
        slot_context.route_string_tier_3 = 0;
        slot_context.route_string_tier_4 = 0;
        slot_context.route_string_tier_5 = 0;
        slot_context.speed = port_speed; //TODO: unnecessary?
        slot_context.reserved = 0;
        slot_context.mtt = false;
        slot_context.is_hub = false;
        slot_context.context_entries = 1;
        slot_context.max_exit_latency = 0; //TODO: not sure why this is 0 yet
        slot_context.root_hub_port_number = @as(u8, @intCast(port_number));
        slot_context.number_of_ports = 0; //not a hub, so 0
    }

    //4. Allocate and initialize the Transfer Ring for the Default Control Endpoint. Refer to section 4.9 for TRB Ring initialization requirements and to section 6.4 for the formats of TRBs.
    var endpoint_0_transfer_ring: *TransferRing = undefined;
    var endpoint_0_transfer_ring_physical_address: u64 = 0;
    {
        const transfer_trb_ring_allocation_result = alloc_object_aligned(
            TransferRing,
            w64.MMIO_PAGE_SIZE,
            device_arena,
        );
        endpoint_0_transfer_ring = transfer_trb_ring_allocation_result.data;

        var trb_ring: TransferRequestBlockRing = undefined;
        initialize_trb_ring(&trb_ring, transfer_trb_ring_allocation_result.physical_address_start, true);
        endpoint_0_transfer_ring.* = .{
            .trb_ring = trb_ring,
            .doorbell = doorbell,
        };
        endpoint_0_transfer_ring_physical_address = transfer_trb_ring_allocation_result.physical_address_start;
    }

    //5. Initialize the Input default control Endpoint 0 Context (6.2.3).
    //• EP Type = Control.
    //• Max Packet Size = The default maximum packet size for the Default Control Endpoint, as function of the PORTSC Port Speed field.
    //• Max Burst Size = 0.
    //• TR Dequeue Pointer = Start address of first segment of the Default Control
    //Endpoint Transfer Ring.
    //• Dequeue Cycle State (DCS) = 1. Reflects Cycle bit state for valid TRBs written
    //by software.
    //• Interval = 0.
    //• Max Primary Streams (MaxPStreams) = 0.
    //• Mult = 0.
    //• Error Count (CErr) = 3.
    //TD -> Transfer Descriptor
    const max_packet_size: u16 = switch (port_speed) {
        .LowSpeed => 8,
        .FullSpeed, .HighSpeed => 64,
        .SuperSpeed => 512,
        else => {
            return error.InvalidSpeedOnUSBPort;
        },
    };

    const control_endpoint_context = get_endpoint_context_from_input_context(1, input_context);
    control_endpoint_context.reserved0 = 0;
    control_endpoint_context.cerr = 3;
    control_endpoint_context.transfer_type = .Control;
    control_endpoint_context.is_control_or_input_endpoint = true;
    control_endpoint_context.reserved1 = 0;
    control_endpoint_context.hid = false;
    control_endpoint_context.max_burst_size = 0;
    control_endpoint_context.max_packet_size = max_packet_size;
    control_endpoint_context.dcs = 1;
    control_endpoint_context.tr_dequeue_pointer = @as(u60, @intCast(endpoint_0_transfer_ring_physical_address >> 4));
    control_endpoint_context.average_trb_length = 8; //TODO: no idea why this 8.  Gotten from Essence and HaikuOS
    control_endpoint_context.max_esit_payload_lo = 0;
    //6. Allocate the Output Device Context data structure (6.2.1) and initialize it to ‘0’.

    const output_device_context_allocation_result = alloc_slice_aligned(
        u32,
        context_size_in_words * 32,
        w64.MMIO_PAGE_SIZE,
        device_arena,
    );
    const output_device_context = DeviceContext{
        .context_size_in_words = context_size_in_words,
        .physical_address = output_device_context_allocation_result.physical_address_start,
        .data = output_device_context_allocation_result.data,
    };

    //7. Load the appropriate (Device Slot ID) entry in the Device Context Base Address Array (5.4.6) with a pointer to the Output Device Context data structure (6.2.1).
    device_slots[slot_id] = output_device_context_allocation_result.physical_address_start;

    return DeviceSlotDataStructures{
        .input_context = input_context,
        .output_device_context = output_device_context,

        .endpoint_0_transfer_ring = endpoint_0_transfer_ring,

        .endpoint_0_transfer_ring_physical_address = endpoint_0_transfer_ring_physical_address,
    };
}

fn submit_command(
    command: TransferRequestBlock,
    controller: *Controller,
) !PollEventRingResult {
    const command_trb_ring = controller.command_ring;
    //write command block to the command ring
    const transfer_trb_phyiscal_address: u64 = command_trb_ring.ring.physical_address_of_current_index();
    {
        var trb = &command_trb_ring.ring.ring[command_trb_ring.ring.index];
        trb.* = command;
        trb.write_cycle_bit(command_trb_ring.ring.cs);
        command_trb_ring.ring.index += 1;
        if (command_trb_ring.ring.index >= command_trb_ring.ring.ring.len - 1) {
            //reached the link TRB, now wrap back to the beginning
            command_trb_ring.ring.cs ^= 1;
            command_trb_ring.ring.ring[command_trb_ring.ring.index].write_cycle_bit(command_trb_ring.ring.cs);
            command_trb_ring.ring.index = 0;
        }
    }

    @fence(.SeqCst);
    //ring the doorbell.  0 is the only valid value for ringing the
    //command trb doorbell (Host Controller Command)
    command_trb_ring.doorbell.* = 0;

    //TODO timeout
    return wait_for_transfer_response(
        transfer_trb_phyiscal_address,
        controller,
    );
}

fn wait_for_transfer_response(
    transfer_trb_phyiscal_address: usize,
    controller: *Controller,
) !PollEventRingResult {
    const timeout_ms = 1000;
    const deadline_ms = toolbox.now().milliseconds() + timeout_ms;
    profiler.begin("Wait for xHCI transfer");
    defer profiler.end();
    while (true) {
        if (poll_controller(controller, false)) {
            const response_opt = controller.event_response_map.get(transfer_trb_phyiscal_address);
            if (response_opt) |response| {
                controller.event_response_map.remove(transfer_trb_phyiscal_address);

                if (response.err) |e| {
                    return e;
                }
                return response;
            }
        }
        if (toolbox.now().milliseconds() >= deadline_ms) {
            return error.TimeoutWaitingForTransferResponse;
        }
        std.atomic.spinLoopHint();
    }
}

fn initialize_trb_ring(trb_ring: *TransferRequestBlockRing, trb_ring_physical_address: u64, setup_link_trb: bool) void {
    trb_ring.* = .{
        .ring = [_]TransferRequestBlock{.{
            .data_pointer = 0,
            .status = 0,
            .control = 0,
        }} ** TransferRequestBlockRing.RING_SIZE,
        .index = 0,
        .cs = 1,
        .physical_address_start = trb_ring_physical_address,
    };

    if (setup_link_trb) {
        //set up link TRB
        trb_ring.ring[TransferRequestBlockRing.RING_SIZE - 1] = .{
            .data_pointer = trb_ring_physical_address,
            .status = 0,
            .control = (6 << 10) | (1 << 1), //| (1 << 0), //set CS bit, TC bit and TRB Type to Link
        };
    }
}
//const interface_class = switch (interface_descriptor.interface_class) {
//0x1 => "Audio",
//0x2 => "Communications and CDC Control",
//0x3 => "HID (Human Interface Device)",
//0x5 => "Physical",
//0x6 => "Image",
//0x7 => "Printer",
//0x8 => "Mass Storage",
//0x9 => "Hub",
//0xA => "CDC-Data",
//0xB => "Smart Card",
//0xD => "Content Security",
//0xE => "Video",
//0xF => "Personal Healthcare",
//0x10 => "Audio/Video Devices",
//0x11 => "Billboard Device Class",
//0x12 => "USB Type-C Bridge Class",
//0xDC => "Diagnostic Device",
//0xE0 => "Wireless Controller",
//0xEF => "Miscellaneous",
//0xFE => "Application Specific",
//0xFF => "Vendor Specific",
//else => "Unknown Interface",
//};

pub fn completion_code_to_error(completion_code: u8) anyerror {
    return switch (completion_code) {
        2 => return error.DataBufferError,
        3 => return error.BabbleDetectedError,
        4 => return error.USBTransactionError,
        5 => return error.TRBError,
        6 => return error.StallError,
        7 => return error.ResourceError,
        8 => return error.BandwidthError,
        9 => return error.NoAvailableSlotsError,
        10 => return error.InvalidStreamTypeError,
        11 => return error.SlotNotEnabledError,
        12 => return error.EndpointNotEnabledError,
        13 => return error.ShortPacketError,
        else => return error.UnknownCompletionCodeError,
    };
}

fn AllocationResultObject(comptime T: type, comptime alignment: usize) type {
    return struct {
        data: *align(alignment) T,
        physical_address_start: u64,
    };
}
fn AllocationResultSlice(comptime T: type, comptime alignment: usize) type {
    return struct {
        data: []align(alignment) T,
        physical_address_start: u64,
    };
}
inline fn alloc_object(
    comptime T: type,
    arena: *toolbox.Arena,
) AllocationResultObject(T, @alignOf(T)) {
    return alloc_object_aligned(T, @alignOf(T), arena);
}

fn alloc_object_aligned(
    comptime T: type,
    comptime alignment: usize,
    arena: *toolbox.Arena,
) AllocationResultObject(T, alignment) {
    const obj = arena.push_clear_aligned(T, alignment);
    const physical_address = kernel_memory.virtual_to_physical(@intFromPtr(obj));
    if (physical_address == 0) {
        toolbox.panic("Could not find physical address for virtual address {X}", .{@intFromPtr(obj)});
    }
    return .{
        .data = obj,
        .physical_address_start = physical_address,
    };
}
inline fn alloc_slice(
    comptime T: type,
    n: usize,
    arena: *toolbox.Arena,
) AllocationResultSlice(T, @alignOf(T)) {
    return alloc_slice_aligned(T, n, @alignOf(T), arena);
}

fn alloc_slice_aligned(
    comptime T: type,
    n: usize,
    comptime alignment: usize,
    arena: *toolbox.Arena,
) AllocationResultSlice(T, @alignOf(T)) {
    const slice = arena.push_slice_clear_aligned(
        T,
        n,
        alignment,
    );
    const physical_address = kernel_memory.virtual_to_physical(@intFromPtr(slice.ptr));
    if (physical_address == 0) {
        toolbox.panic("Could not find physical address for virtual address {X}", .{@intFromPtr(slice.ptr)});
    }
    return .{
        .data = slice,
        .physical_address_start = physical_address,
    };
}

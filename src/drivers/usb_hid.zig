const usb_xhci = @import("usb_xhci.zig");
const toolbox = @import("toolbox");
const w64 = @import("../wozmon64.zig");
const kernel = @import("../kernel.zig");

const print_serial = kernel.print_serial;

pub const USBHIDDevice = struct {
    device_types: []Type,
    interface: *usb_xhci.Interface,
    input_endpoint: usb_xhci.Endpoint,
    packet_buffer: []u8,
    packet_buffer_physical_address: u64,
    last_transfer_request_physical_address: u64,
    items: []Item,

    const Type = union(enum) {
        Keyboard: USBHIDKeyboard,
        Mouse: USBHIDMouse,
    };
};
pub const Descriptor = packed struct {
    length: u8,
    descriptor_type: usb_xhci.DescriptorType,
    hid_version: u16,
    country_code: u8,
    num_descriptors: u8,
    report_descriptor_type: u8,
    report_descriptor_length: u16,
};

const ReportDescriptorByteStream = struct {
    data: []u8,
};
const ItemType = enum(u8) {
    GlobalUsagePage = 0x04,
    GlobalLogicalMinimum = 0x14,
    GlobalLogicalMaximum = 0x24,
    GlobalPhysicalMinimum = 0x34,
    GlobalPhysicalMaximum = 0x44,
    GlobalUnitExponent = 0x54,
    GlobalUnit = 0x64,
    GlobalReportSize = 0x74,
    GlobalReportID = 0x84,
    GlobalReportCount = 0x94,
    GlobalPush = 0xA4,
    GlobalPop = 0xB4,

    LocalUsage = 0x08,
    LocalUsageMinimum = 0x18,
    LocalUsageMaximum = 0x28,
    LocalDesignatorIndex = 0x38,
    LocalDesignatorMinimum = 0x48,
    LocalDesignatorMaximum = 0x58,
    //No 0x68
    LocalStringIndex = 0x78,
    LocalStringMinimum = 0x88,
    LocalStringMaximum = 0x98,
    LocalDelimeter = 0xA8,

    //Main items
    Input = 0x80,
    Output = 0x90,
    Feature = 0xB0,
    Collection = 0xA0,
    EndCollection = 0xC0,

    LongItem = 0xFE,
    End,
    _,
};
const Item = union(ItemType) {
    GlobalUsagePage: u32,
    GlobalLogicalMinimum: u32,
    GlobalLogicalMaximum: u32,
    GlobalPhysicalMinimum: u32,
    GlobalPhysicalMaximum: u32,
    GlobalUnitExponent: u32,
    GlobalUnit: u32,
    GlobalReportSize: u32,
    GlobalReportID: u32,
    GlobalReportCount: u32,
    GlobalPush: u32,
    GlobalPop: u32,

    LocalUsage: u32,
    LocalUsageMinimum: u32,
    LocalUsageMaximum: u32,
    LocalDesignatorIndex: u32,
    LocalDesignatorMinimum: u32,
    LocalDesignatorMaximum: u32,
    LocalStringIndex: u32,
    LocalStringMinimum: u32,
    LocalStringMaximum: u32,
    LocalDelimeter: u32,

    //Main items
    Input: u32,
    Output: u32,
    Feature: u32,
    Collection: u32,
    EndCollection: u32,
    LongItem: void, //unused
    End: void,
};
const UsagePage = enum {
    Undefined,
    GenericDesktopControls,
    SimulationControls,
    VRControls,
    SportControls,
    GameControls,
    GenericDeviceControls,
    KeyboardOrKeypad,
    LEDs,
    Button,
    Ordinal,
    Telephony,
    Consumer,
    Digitizer,
    PIDPage,
    Unicode,
    AlphanumericDisplay,
    MedicalInstruments,
    MonitorPages,
    PowerPages,
    BarCodeScannerPage,
    ScalePage,
    MagneticStripeReadingDevices,
    CameraControlPage,
    ArcadePage,
    VendorDefined,
    Reserved,
};
const Usage = struct {
    usage_page: UsagePage,
    usage: u32,
};
const ReportElement = struct {
    index: u32,
    size: u32,
};
const USBHIDMouseScaffold = struct {
    x_report: ?ReportElement,
    y_report: ?ReportElement,
    scroll_report: ?ReportElement,
    button_report: ?ReportElement,
};
const USBHIDMouse = struct {
    x_report: ReportElement,
    y_report: ReportElement,
    scroll_report: ReportElement,
    button_report: ReportElement,
};
const USBHIDKeyboard = struct {
    modifier_report: ReportElement,
    keys_pressed_report: ReportElement,

    keys_held: [NUM_KEYS_IN_REPORT]u8,
    modifier_keys_held: u8,

    const NUM_KEYS_IN_REPORT = 6;
};
const USBHIDKeyboardScaffold = struct {
    modifier_report: ?ReportElement,
    keys_pressed_report: ?ReportElement,
};
//StateMachine = {
//  global:
//  usage_page
//  report_id -- optional
//  total_report_bit_size -- report_count * report_size
//  report_size  -- size is in bits
//
//  local:
//  usages -- optional
//  usage_maxes -- optional
//  usage_mins -- optional
//}
//
//Keyboard:
//detect:
//-usage_page == Generic Desktop Controls(0x1) and contains(Keyboard(0x6), usages) -> indicates that it's a keyboard
//expect:
//-usage_page == Keyboard/Keypad(0x7) and index1 = contains(0xE0, usage_mins) and index2 = contains(0xE7, usage_maxs) and index1 == index2 and total_report_bit_size == 8
//-usage_page == Keyboard/Keypad(0x7) and contains(0x0, usage_mins) and contains(0xFF, usage_maxs) and total_report_bit_size == 48
//
//
//Mouse:
//detect:
//-usage_page == Generic Desktop Controls(0x1) and contains(Mouse(0x2), usages) and contains(Pointer(0x1), usages) -> indicates that it's a keyboard
//expect:
//-usage_page == Button(0x9) and index1 = contains(0x1, usage_mins) and index2 = contains(0x3, usage_maxs) and index1 == index2 and total_report_bit_size == 3
//-usage_page == Generic Desktop Controls(0x1) and contains(0x30, usages) and contains(0x31, usages) and contains(0x38, usages) and total_report_size == 24
//
//TODO: Figure out when when build_keyboard() and build_mouse() should return.  This only matters for the ducky keyboard.  Need to look into the token stream of maybe there is some sort of "divider" item between the keyboard definition and mouse definition

//if detected(keyboard) {
//   add(re
//}
//
//devices: DynamicArray(HIDDevices)
//while (token != End) {
//    switch (token) {
//       Keyboard => {
//
//           keyboard_ptr = add(empty_keyboard, &devices);
//           state.keyboard_in_progress = keyboard_ptr;
//       },
//       Mouse => {
//           mouse_ptr = add(empty_mouse, &devices);
//           state.mouse_in_progress = keyboard_ptr;
//       },
//    }
//}

fn contains_usage(usage: Usage, usages: toolbox.DynamicArray(Usage)) bool {
    for (usages.items()) |other| {
        if (usage.usage_page == other.usage_page and usage.usage == other.usage) {
            return true;
        }
    }
    return false;
}
fn within_usage_range(
    usage: Usage,
    min_usages: toolbox.DynamicArray(Usage),
    max_usages: toolbox.DynamicArray(Usage),
) bool {
    toolbox.assert(
        min_usages.len() == max_usages.len(),
        "# of usage numbers mismatch. Max usage numbers len: {}, Min usage numbers len: {}",
        .{ min_usages.len(), max_usages.len() },
    );
    for (min_usages.items(), max_usages.items()) |min, max| {
        if (usage.usage_page == min.usage_page and usage.usage_page == max.usage_page and
            usage.usage >= min.usage and usage.usage <= max.usage)
        {
            return true;
        }
    }
    return false;
}
pub fn init_hid_interface(
    hid_interface: *usb_xhci.Interface,
    hid_descriptor: Descriptor,
    scratch_arena: *toolbox.Arena,
    mapped_memory: *const toolbox.RandomRemovalLinkedList(w64.VirtualMemoryMapping),
) !void {
    const save_point = scratch_arena.create_save_point();
    defer scratch_arena.restore_save_point(save_point);
    const in_endpoint = b: {
        for (hid_interface.endpoints) |endpoint| {
            if (endpoint.direction == .In) {
                break :b endpoint;
            }
        } else {
            return error.HIDDeviceDoesNotHaveAnInterruptEndpoint;
        }
    };
    const controller = hid_interface.parent_device.parent_controller;
    const device = hid_interface.parent_device;
    const full_hid_descriptor_result =
        alloc_slice(u8, hid_descriptor.report_descriptor_length, scratch_arena, mapped_memory);
    const full_hid_descriptor = full_hid_descriptor_result.data;
    const full_hid_descriptor_physical_address = full_hid_descriptor_result.physical_address_start;
    const initial_array_size = 8;

    try usb_xhci.get_descriptor_from_endpoint0(
        full_hid_descriptor_physical_address,
        hid_descriptor.report_descriptor_length,
        .Interface,
        0,
        @enumFromInt(hid_descriptor.report_descriptor_type), //hid_descriptor.descriptor_type,
        hid_interface.interface_number,
        device.endpoint_0_transfer_ring,
        controller,
    );
    print_serial("Device {?s} Interface: {} Number of endpoints: {}", .{
        device.product,
        hid_interface.interface_number,
        hid_interface.endpoints.len,
    });

    var byte_stream = ReportDescriptorByteStream{
        .data = full_hid_descriptor,
    };
    var item = try next_item(&byte_stream);
    var usage_page: ?UsagePage = .Undefined;
    var usages = toolbox.DynamicArray(Usage).init(scratch_arena, initial_array_size);
    var usage_minimums = toolbox.DynamicArray(Usage).init(scratch_arena, initial_array_size);
    var usage_maximums = toolbox.DynamicArray(Usage).init(scratch_arena, initial_array_size);
    var report_id: ?u32 = null;
    var logical_minimum: ?u32 = 0;
    var logical_maximum: ?u32 = 0;
    var report_size: ?u32 = 0;
    var report_count: ?u32 = 0;
    var mouse_to_build: ?USBHIDMouseScaffold = null;
    var keyboard_to_build: ?USBHIDKeyboardScaffold = null;
    var bit_index: u32 = 0;

    var device_types_parsed = toolbox.DynamicArray(USBHIDDevice.Type).init(device.arena, initial_array_size);
    var items = toolbox.DynamicArray(Item).init(device.arena, initial_array_size);

    while (item != .End) : (item = try next_item(&byte_stream)) {
        items.append(item);
        switch (item) {
            .GlobalUsagePage => |data| {
                usage_page = data_to_usage_page(data);
            },
            .GlobalLogicalMinimum => |data| {
                logical_minimum = data;
            },
            .GlobalLogicalMaximum => |data| {
                logical_maximum = data;
            },
            .GlobalReportSize => |data| {
                report_size = data;
            },
            .GlobalReportCount => |data| {
                report_count = data;
            },
            .LocalUsage => |data| {
                if (usage_page == null) {
                    return error.MissingUsagePageForUsage;
                }
                usages.append(Usage{
                    .usage_page = usage_page.?,
                    .usage = data,
                });
            },
            .LocalUsageMinimum => |data| {
                if (usage_page == null) {
                    return error.MissingUsagePageForUsageMinimum;
                }
                usage_minimums.append(Usage{
                    .usage_page = usage_page.?,
                    .usage = data,
                });
            },
            .LocalUsageMaximum => |data| {
                if (usage_page == null) {
                    return error.MissingUsagePageForUsageMaximum;
                }
                usage_maximums.append(Usage{
                    .usage_page = usage_page.?,
                    .usage = data,
                });
            },

            .GlobalReportID => |data| {
                //TODO
                report_id = data;
                return error.ReportIDsNotYetSupported;
            },
            //Main items
            .Input,
            .Output,
            .Feature,
            => {
                if (usage_page == null) {
                    return error.MissingUsagePage;
                }
                if (logical_minimum == null) {
                    return error.MissingLogicalMinimum;
                }
                if (logical_maximum == null) {
                    return error.MissingLogicalMaximum;
                }
                if (report_size == null) {
                    return error.MissingReportSize;
                }
                if (report_count == null) {
                    return error.MissingReportCount;
                }
                if (usage_minimums.len() != usage_maximums.len()) {
                    return error.InvalidNumberOfUsageMinimumsAndMaximums;
                }
                if (usages.len() > 0) {
                    if (contains_usage(.{ .usage_page = .GenericDesktopControls, .usage = 2 }, usages)) {
                        if (mouse_to_build != null) {
                            return error.MoreThanOneMouseInInterfaceNotSupported;
                        }
                        mouse_to_build = .{
                            .x_report = null,
                            .y_report = null,
                            .scroll_report = null,
                            .button_report = null,
                        };
                    }
                    if (contains_usage(.{ .usage_page = .GenericDesktopControls, .usage = 6 }, usages)) {
                        if (keyboard_to_build != null) {
                            return error.MoreThanOneKeyboardInInterfaceNotSupported;
                        }
                        keyboard_to_build = .{
                            .modifier_report = null,
                            .keys_pressed_report = null,
                        };
                    }
                    var local_bit_index = bit_index;
                    if (mouse_to_build) |*scaffold| {
                        for (usages.items()) |usage| {
                            if (usage.usage_page == .GenericDesktopControls) {
                                switch (usage.usage) {
                                    0x30 => {
                                        const size = bits_to_bytes(report_size.?);
                                        if (size <= 2 and size > 0) {
                                            scaffold.x_report = .{ .index = local_bit_index / 8, .size = size };
                                        }
                                    },
                                    0x31 => {
                                        const size = bits_to_bytes(report_size.?);
                                        if (size <= 2 and size > 0) {
                                            scaffold.y_report = .{ .index = local_bit_index / 8, .size = bits_to_bytes(report_size.?) };
                                        }
                                    },
                                    0x38 => {
                                        const size = bits_to_bytes(report_size.?);
                                        if (size <= 2 and size > 0) {
                                            scaffold.scroll_report = .{ .index = local_bit_index / 8, .size = bits_to_bytes(report_size.?) };
                                        }
                                    },
                                    else => {},
                                }
                            }
                            local_bit_index += report_size.?;
                        }
                        if (scaffold.button_report != null and scaffold.x_report != null and scaffold.y_report != null and
                            scaffold.scroll_report != null)
                        {
                            device_types_parsed.append(.{ .Mouse = .{
                                .button_report = scaffold.button_report.?,
                                .x_report = scaffold.x_report.?,
                                .y_report = scaffold.y_report.?,
                                .scroll_report = scaffold.scroll_report.?,
                            } });
                            mouse_to_build = null;
                        }
                    }
                    usages.clear();
                }
                if (usage_minimums.len() > 0) {
                    if (keyboard_to_build) |*scaffold| {
                        //0xEO is Left Control
                        if (within_usage_range(.{ .usage_page = .KeyboardOrKeypad, .usage = 0xE0 }, usage_minimums, usage_maximums) and
                            report_size.? * report_count.? <= 8)
                        {
                            scaffold.modifier_report = .{ .index = bit_index / 8, .size = bits_to_bytes(report_size.? * report_count.?) };
                        }
                        //0x50 is Left Arrow
                        if (within_usage_range(.{ .usage_page = .KeyboardOrKeypad, .usage = 0x50 }, usage_minimums, usage_maximums) and
                            report_size.? == 8 and report_count.? == USBHIDKeyboard.NUM_KEYS_IN_REPORT) //TODO have a special case for > 48 for n-key rollover
                        {
                            scaffold.keys_pressed_report = .{ .index = bit_index / 8, .size = bits_to_bytes(report_size.? * report_count.?) };
                        }
                        if (scaffold.keys_pressed_report != null and scaffold.modifier_report != null) {
                            device_types_parsed.append(.{ .Keyboard = .{
                                .keys_pressed_report = scaffold.keys_pressed_report.?,
                                .modifier_report = scaffold.modifier_report.?,
                                .modifier_keys_held = 0,
                                .keys_held = [_]u8{0} ** USBHIDKeyboard.NUM_KEYS_IN_REPORT,
                            } });
                            keyboard_to_build = null;
                        }
                    }
                    if (mouse_to_build) |*scaffold| {
                        //0x1 is left mouse button
                        if (within_usage_range(.{ .usage_page = .Button, .usage = 0x1 }, usage_minimums, usage_maximums)) {
                            scaffold.button_report = .{ .index = bit_index / 8, .size = bits_to_bytes(report_size.? * report_count.?) };
                        }
                        if (scaffold.button_report != null and scaffold.x_report != null and scaffold.y_report != null and
                            scaffold.scroll_report != null)
                        {
                            device_types_parsed.append(.{ .Mouse = .{
                                .button_report = scaffold.button_report.?,
                                .x_report = scaffold.x_report.?,
                                .y_report = scaffold.y_report.?,
                                .scroll_report = scaffold.scroll_report.?,
                            } });
                            mouse_to_build = null;
                        }
                    }
                    usage_minimums.clear();
                    usage_maximums.clear();
                }
                if (item == .Input) {
                    bit_index += report_size.? * report_count.?;
                }
            },
            //TODO: i'm not sure if this is necessary?
            //.Collection => |data| {
            //current_collection_number = data;
            //},
            //.EndCollection => {
            //if (report_descriptors.items.len > 0) {
            //try kernel_memory.append_to_dynamic_array(Collection{
            //.number = current_collection_number,
            //.report_descriptors = report_descriptors.items,
            //}, &collections);
            //report_descriptors = try kernel_memory.init_dynamic_array(ReportDescriptor, initial_array_size, &device.arena);
            //}
            //},

            .GlobalPush,
            .GlobalPop,
            => {
                @panic("Push and pop unsupported!");
            },

            //TODO
            .LocalDesignatorIndex,
            .LocalDesignatorMinimum,
            .LocalDesignatorMaximum,
            .LocalStringIndex,
            .LocalStringMinimum,
            .LocalStringMaximum,
            .LocalDelimeter,
            .GlobalPhysicalMinimum,
            .GlobalPhysicalMaximum,
            .GlobalUnitExponent,
            .GlobalUnit,
            => {},

            else => {},
        }
    }

    const endpoint_packet_buffer_result = alloc_slice(
        u8,
        in_endpoint.endpoint_context.max_packet_size,
        device.arena,
        mapped_memory,
    );

    var hid_device = USBHIDDevice{
        .items = items.items(),
        .device_types = device_types_parsed.items(),
        .interface = hid_interface,
        .input_endpoint = in_endpoint,
        .packet_buffer = endpoint_packet_buffer_result.data,
        .packet_buffer_physical_address = endpoint_packet_buffer_result.physical_address_start,
        .last_transfer_request_physical_address = 0,
    };
    queue_transfer_trb(&hid_device);
    _ = device.hid_devices.append(hid_device);
}
fn bits_to_bytes(bits: u32) u32 {
    return bits / 8 + (if (bits % 8 > 0) @as(u32, 1) else @as(u32, 0));
}
fn next_item(byte_stream: *ReportDescriptorByteStream) !Item {
    if (byte_stream.data.len == 0) {
        return .End;
    }
    if (byte_stream.data[0] == @intFromEnum(ItemType.LongItem)) {
        const item_len = byte_stream.data[1];
        if (item_len > byte_stream.data.len - 3) {
            return error.InvalidLongItemLen;
        }
        byte_stream.data = byte_stream.data[3 + item_len + 1 ..];
        return .LongItem;
    }
    const item_type = @as(ItemType, @enumFromInt(byte_stream.data[0] & 0xFC));
    var data_len = byte_stream.data[0] & 3;
    if (data_len == 3) {
        data_len = 4; //if the lower 2 bits are 3, then the length is 4 bytes
    }
    if (data_len > byte_stream.data.len - 1) {
        return error.BadShortItemLength;
    }
    const data = switch (data_len) {
        0 => @as(u32, 0),
        1 => @as(u32, byte_stream.data[1]),
        2 => (@as(u32, byte_stream.data[2]) << 8) | @as(u32, byte_stream.data[1]),
        4 => (@as(u32, byte_stream.data[4]) << 24) | (@as(u32, byte_stream.data[3]) << 16) | (@as(u32, byte_stream.data[2]) << 8) | @as(u32, byte_stream.data[1]),
        else => unreachable,
    };
    byte_stream.data = byte_stream.data[1 + data_len ..];
    return switch (item_type) {
        .GlobalUsagePage => .{ .GlobalUsagePage = data },
        .GlobalLogicalMinimum => .{ .GlobalLogicalMinimum = data },
        .GlobalLogicalMaximum => .{ .GlobalLogicalMaximum = data },
        .GlobalPhysicalMinimum => .{ .GlobalPhysicalMinimum = data },
        .GlobalPhysicalMaximum => .{ .GlobalPhysicalMaximum = data },
        .GlobalUnitExponent => .{ .GlobalUnitExponent = data },
        .GlobalUnit => .{ .GlobalUnit = data },
        .GlobalReportSize => .{ .GlobalReportSize = data },
        .GlobalReportID => .{ .GlobalReportID = data },
        .GlobalReportCount => .{ .GlobalReportCount = data },
        .GlobalPush => .{ .GlobalPush = data },
        .GlobalPop => .{ .GlobalPop = data },

        .LocalUsage => .{ .LocalUsage = data },
        .LocalUsageMinimum => .{ .LocalUsageMinimum = data },
        .LocalUsageMaximum => .{ .LocalUsageMaximum = data },
        .LocalDesignatorIndex => .{ .LocalDesignatorIndex = data },
        .LocalDesignatorMinimum => .{ .LocalDesignatorMinimum = data },
        .LocalDesignatorMaximum => .{ .LocalDesignatorMaximum = data },
        .LocalStringIndex => .{ .LocalStringIndex = data },
        .LocalStringMinimum => .{ .LocalStringMinimum = data },
        .LocalStringMaximum => .{ .LocalStringMaximum = data },
        .LocalDelimeter => .{ .LocalDelimeter = data },

        //.Main items
        .Input => .{ .Input = data },
        .Output => .{ .Output = data },
        .Feature => .{ .Feature = data },
        .Collection => .{ .Collection = data },
        .EndCollection => .{ .EndCollection = data },

        else => error.BadReportDescriptorItem,
    };
    //return error.UnknownErrorParsingReportDescriptor;
}
fn data_to_usage_page(data: u32) UsagePage {
    return switch (data) {
        0 => .Undefined,
        1 => .GenericDesktopControls,
        2 => .SimulationControls,
        3 => .VRControls,
        4 => .SportControls,
        5 => .GameControls,
        6 => .GenericDeviceControls,
        7 => .KeyboardOrKeypad,
        8 => .LEDs,
        9 => .Button,
        0xA => .Ordinal,
        0xB => .Telephony,
        0xC => .Consumer,
        0xD => .Digitizer,
        0xE => .PIDPage,
        0x10 => .Unicode,
        0x14 => .AlphanumericDisplay,
        0x40 => .MedicalInstruments,
        0x80...0x83 => .MonitorPages,
        0x84...0x87 => .PowerPages,
        0x8C => .BarCodeScannerPage,
        0x8D => .ScalePage,
        0x8E => .MagneticStripeReadingDevices,
        0x90 => .CameraControlPage,
        0x91 => .ArcadePage,
        0xFF00...0xFFFF => .VendorDefined,
        else => .Reserved,
    };
}
fn queue_transfer_trb(hid_device: *USBHIDDevice) void {
    const request_trb = usb_xhci.NormalTRB{
        .data_buffer_pointer = hid_device.packet_buffer_physical_address,
        .trb_transfer_length = @as(u17, @intCast(hid_device.packet_buffer.len)),
        .td_size = 0, //number of packets left
        .interrupter_target = 0,
        .cycle_bit = 0,
        .ent = false, //evaluate next trb
        .isp = false, //interrupt on short packet
        .ns = false, //no snoop
        .ch = 0, //chain bit
        .ioc = true, //interrupt on completion
        .idt = false, //immediate data
        .reserved1 = 0,
        .bei = false, //block event interrupt
        .trb_type = 1, //normal
        .reserved2 = 0,
    };
    var trb_ring = &hid_device.input_endpoint.transfer_ring.trb_ring;
    // preboot_console.clear();
    //TODO split each trb into max packet
    const trb_to_store = @as(usb_xhci.TransferRequestBlock, @bitCast(request_trb));
    var trb = &trb_ring.ring[trb_ring.index];
    trb.* = trb_to_store;
    trb.write_cycle_bit(trb_ring.cs);
    @fence(.SeqCst);
    hid_device.input_endpoint.transfer_ring.doorbell.* = hid_device.input_endpoint.doorbell_value;
    hid_device.last_transfer_request_physical_address = trb_ring.physical_address_of_current_index();

    trb_ring.index += 1;
    if (trb_ring.index >= trb_ring.ring.len - 1) {
        //reached the link TRB, now wrap back to the beginning
        trb_ring.ring[trb_ring.index].write_cycle_bit(trb_ring.cs);
        trb_ring.cs ^= 1;
        trb_ring.index = 0;
    }
}
pub fn poll(
    controller: *usb_xhci.Controller,
    input_state: *w64.InputState,
) void {
    //TODO have hash map instead of this double loop nonsense
    var device_it = controller.devices.iterator();
    while (device_it.next_value()) |device| {
        var hid_device_it = device.hid_devices.iterator();
        while (hid_device_it.next()) |hid_device| {
            if (controller.event_response_map.get(
                hid_device.last_transfer_request_physical_address,
            )) |event_response| {
                if (event_response.err) |e| {
                    print_serial("Error polling device: {}", .{e});
                    continue;
                }
                var number_of_bytes_not_transferred = event_response.number_of_bytes_not_transferred;
                const input_data = hid_device.packet_buffer[0 .. hid_device.packet_buffer.len - number_of_bytes_not_transferred];
                // println("Data from USB device: {x}", .{input_data});
                for (hid_device.device_types) |*device_type| {
                    handle_input_data(input_data, device_type, input_state);
                }
                controller.event_response_map.remove(
                    hid_device.last_transfer_request_physical_address,
                );
                queue_transfer_trb(hid_device);
            }
        }
    }
}
fn mouse_report_to_int(data: []const u8) i16 {
    switch (data.len) {
        1 => return @as(i16, toolbox.data_to_int(data, i8)),
        2 => return @as(i16, toolbox.data_to_int(data, i16)),
        else => unreachable,
    }
}
fn usb_scancode_to_boksos_scancode(usb_scancode: u8) ?w64.ScanCode {
    const ret: ?w64.ScanCode = switch (usb_scancode) {
        0x4 => .A,
        0x5 => .B,
        0x6 => .C,
        0x7 => .D,
        0x8 => .E,
        0x9 => .F,
        0xA => .G,
        0xB => .H,
        0xC => .I,
        0xD => .J,
        0xE => .K,
        0xF => .L,
        0x10 => .M,
        0x11 => .N,
        0x12 => .O,
        0x13 => .P,
        0x14 => .Q,
        0x15 => .R,
        0x16 => .S,
        0x17 => .T,
        0x18 => .U,
        0x19 => .V,
        0x1A => .W,
        0x1B => .X,
        0x1C => .Y,
        0x1D => .Z,

        0x1E => .One,
        0x1F => .Two,
        0x20 => .Three,
        0x21 => .Four,
        0x22 => .Five,
        0x23 => .Six,
        0x24 => .Seven,
        0x25 => .Eight,
        0x26 => .Nine,
        0x27 => .Zero,

        0x28 => .Enter,
        0x29 => .Escape,
        0x2A => .Backspace,
        0x2B => .Tab,
        0x2C => .Space,
        0x2D => .Hyphen,
        0x2E => .Equals,
        0x2F => .LeftBracket,
        0x30 => .RightBracket,
        0x31 => .Backslash,

        //TODO
        //0x32 => NOTE: for non-US keyboards only
        0x33 => .Semicolon,
        0x34 => .Quote,
        0x35 => .Backtick,
        0x36 => .Comma,
        0x37 => .Period,
        0x38 => .Slash,
        0x39 => .CapsLock,
        0x3A => .F1,
        0x3B => .F2,
        0x3C => .F3,
        0x3D => .F4,
        0x3E => .F5,
        0x3F => .F6,
        0x40 => .F7,
        0x41 => .F8,
        0x42 => .F9,
        0x43 => .F10,
        0x44 => .F11,
        0x45 => .F12,

        0x46 => .PrintScreen,
        0x47 => .ScrollLock,
        0x48 => .Pause,
        0x49 => .Insert,
        0x4A => .Home,
        0x4B => .PageUp,
        0x4C => .Delete,
        0x4D => .End,
        0x4E => .PageDown,
        0x4F => .RightArrow,
        0x50 => .LeftArrow,
        0x51 => .DownArrow,
        0x52 => .UpArrow,

        0x53 => .NumLock,
        0x54 => .NumDivide,
        0x55 => .NumMultiply,
        0x56 => .NumSubtract,
        0x57 => .NumAdd,
        0x58 => .NumEnter,

        0x59 => .Num1,
        0x5A => .Num2,
        0x5B => .Num3,
        0x5C => .Num4,
        0x5D => .Num5,
        0x5E => .Num6,
        0x5F => .Num7,
        0x60 => .Num8,
        0x61 => .Num9,
        0x62 => .Num0,
        0x63 => .NumPoint,

        //TODO
        //0x64 => NOTE: for non-US keyboards only

        else => null,
    };
    return ret;
}
fn set_difference(minunend: []const u8, subtrahend: []const u8, result: []u8) void {
    for (minunend, 0..) |m, i| {
        for (subtrahend) |s| {
            if (m == s) {
                break;
            }
        } else {
            result[i] = m;
        }
    }
}
fn handle_input_data(
    data: []const u8,
    device_type: *USBHIDDevice.Type,
    input_state: *w64.InputState,
) void {
    switch (device_type.*) {
        .Keyboard => |_| {
            var keyboard = &device_type.Keyboard;
            //process keyboard modifie keys
            {
                const key_modifiers_held_now = data[keyboard.modifier_report.index];
                const key_modifiers_held_before = keyboard.modifier_keys_held;

                //Example
                //key_modifiers_held_now -> 0000_1001 -> Left control and Left Command  are down
                //key_modifiers_held_before -> 0000_1010 -> Left Shift and Left Command are down
                //send key pressed event for Left Control. send key released event for Left Shift.
                //0000_1001 & 1111_0101 ->
                const key_modifiers_pressed = key_modifiers_held_now & ~key_modifiers_held_before;
                const key_modifiers_released = ~key_modifiers_held_now & key_modifiers_held_before;
                const modifier_scancodes = [_]w64.ScanCode{ .LeftCtrl, .LeftShift, .LeftAlt, .LeftFlag, .RightCtrl, .RightShift, .RightAlt, .RightFlag };
                inline for (modifier_scancodes, 0..) |scancode, i| {
                    if ((key_modifiers_pressed & (1 << i)) != 0) {
                        input_state.modifier_key_pressed_events.enqueue(scancode);
                    }
                    if ((key_modifiers_released & (1 << i)) != 0) {
                        input_state.modifier_key_released_events.enqueue(scancode);
                    }
                }
                keyboard.modifier_keys_held = key_modifiers_held_now;
            }

            const keys_held_now = data[keyboard.keys_pressed_report.index .. keyboard.keys_pressed_report.index +
                keyboard.keys_pressed_report.size];
            var keys_held_before = &keyboard.keys_held;
            var keys_pressed = [_]u8{0} ** USBHIDKeyboard.NUM_KEYS_IN_REPORT;
            var keys_released = [_]u8{0} ** USBHIDKeyboard.NUM_KEYS_IN_REPORT;
            set_difference(keys_held_now, keys_held_before, &keys_pressed);
            set_difference(keys_held_before, keys_held_now, &keys_released);

            for (keys_pressed) |key| {
                if (usb_scancode_to_boksos_scancode(key)) |scancode| {
                    input_state.key_pressed_events.enqueue(scancode);
                }
            }
            for (keys_released) |key| {
                if (usb_scancode_to_boksos_scancode(key)) |scancode| {
                    input_state.key_released_events.enqueue(scancode);
                }
            }

            for (keys_held_before, 0..) |*dest, i| dest.* = keys_held_now[i];
        },

        .Mouse => |_| {
            //TODO: handle mouse event
            // var mouse = &device_type.Mouse;
            // const mouse_event = boksos_input.MouseEvent{
            //     .dx = mouse_report_to_int(data[mouse.x_report.index .. mouse.x_report.index + mouse.x_report.size]),
            //     .dy = mouse_report_to_int(data[mouse.y_report.index .. mouse.y_report.index + mouse.y_report.size]),
            //     .scroll_y = mouse_report_to_int(data[mouse.scroll_report.index .. mouse.scroll_report.index + mouse.scroll_report.size]),
            //     .is_left_button_down = (data[mouse.button_report.index] & (1 << 0)) != 0,
            //     .is_middle_button_down = (data[mouse.button_report.index] & (1 << 2)) != 0,
            //     .is_right_button_down = (data[mouse.button_report.index] & (1 << 1)) != 0,
            // };
            // boksos_input.put_mouse_event(mouse_event);
            //const buttons_pressed = data[mouse.button_report.index];
            //if (buttons_pressed != 0) {
            //println("buttons_pressed: {x}", .{buttons_pressed});
            //}
            //const x_movement = mouse_report_to_int(data[mouse.x_report.index .. mouse.x_report.index + mouse.x_report.size]);
            //if (x_movement != 0) {
            //println("x_movement: {x}", .{x_movement});
            //}
            //const y_movement = mouse_report_to_int(data[mouse.y_report.index .. mouse.y_report.index + mouse.y_report.size]);
            //if (y_movement != 0) {
            //println("y_movement: {x}", .{y_movement});
            //}
        },
    }
}
fn AllocationResultSlice(comptime T: type, comptime alignment: usize) type {
    return struct {
        data: []align(alignment) T,
        physical_address_start: usize,
    };
}
inline fn alloc_slice(
    comptime T: type,
    n: usize,
    arena: *toolbox.Arena,
    mapped_memory: *const toolbox.RandomRemovalLinkedList(w64.VirtualMemoryMapping),
) AllocationResultSlice(T, @alignOf(T)) {
    return alloc_slice_aligned(T, n, @alignOf(T), arena, mapped_memory);
}

fn alloc_slice_aligned(
    comptime T: type,
    n: usize,
    comptime alignment: usize,
    arena: *toolbox.Arena,
    mapped_memory: *const toolbox.RandomRemovalLinkedList(w64.VirtualMemoryMapping),
) AllocationResultSlice(T, @alignOf(T)) {
    const slice = arena.push_slice_clear_aligned(
        T,
        n,
        alignment,
    );
    const physical_address = w64.virtual_to_physical(@intFromPtr(slice.ptr), mapped_memory) catch
        toolbox.panic("Could not find physical address for virtual address {X}", .{@intFromPtr(slice.ptr)});
    return .{
        .data = slice,
        .physical_address_start = physical_address,
    };
}

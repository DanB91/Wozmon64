//Copyright Daniel Bokser 2023
//See LICENSE file for permissible source code usage

const std = @import("std");
const toolbox = @import("toolbox");
const page_allocator = @import("page_allocator.zig");
const w64 = @import("wozmon64.zig");
const amd64 = @import("amd64.zig");
const pcie = @import("drivers/pcie.zig");
const usb_xhci = @import("drivers/usb_xhci.zig");
const usb_hid = @import("drivers/usb_hid.zig");

pub const THIS_PLATFORM = toolbox.Platform.Wozmon64;

const CURSOR_BLINK_TIME_MS = 500;
const ENABLE_SERIAL = true;

const KernelState = struct {
    cursor_x: usize,
    cursor_y: usize,
    last_cursor_update: w64.Time,
    cursor_char: u8,

    screen: w64.Screen,
    root_xsdt: *const amd64.XSDT,
    mapped_memory: toolbox.RandomRemovalLinkedList(w64.VirtualMemoryMapping),
    application_processor_contexts: []*w64.BootloaderProcessorContext,
    next_free_virtual_address: u64,

    usb_xhci_controllers: toolbox.RandomRemovalLinkedList(*usb_xhci.Controller),

    global_arena: *toolbox.Arena,
    frame_arena: *toolbox.Arena,
    scratch_arena: *toolbox.Arena,
};

const StackUnwinder = struct {
    fp: usize,
    fn init() StackUnwinder {
        return .{ .fp = @frameAddress() };
    }
    fn next(self: *StackUnwinder) ?usize {
        if (self.fp == 0 or !toolbox.is_aligned_to(self.fp, @alignOf(usize))) {
            return null;
        }
        const ip = @as(*const usize, @ptrFromInt(self.fp + @sizeOf(usize))).*;
        const new_fp = @as(*const usize, @ptrFromInt(self.fp)).*;
        if (new_fp <= self.fp) {
            return null;
        }
        self.fp = new_fp;
        return ip;
    }
};

pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    //not set
    _ = ret_addr;
    _ = error_return_trace;

    echo_str8("{s}", .{msg});
    var it = StackUnwinder.init();
    while (it.next()) |address| {
        echo_str8("At {X}\n", .{address});
    }
    @memcpy(g_state.screen.frame_buffer, g_state.screen.back_buffer);
    toolbox.hang();
}

var g_state: KernelState = undefined;

export fn kernel_entry(kernel_start_context: *w64.KernelStartContext) callconv(.C) noreturn {
    @setAlignStack(256);
    {
        const frame_arena_bytes =
            kernel_start_context.global_arena.push_bytes_aligned(w64.KERNEL_FRAME_ARENA_SIZE, 8);
        const scratch_arena_bytes =
            kernel_start_context.global_arena.push_bytes_aligned(w64.KERNEL_SCRATCH_ARENA_SIZE, 8);
        w64.Time.init(kernel_start_context.tsc_mhz);
        g_state = .{
            .cursor_x = 0,
            .cursor_y = 0,
            .last_cursor_update = w64.now(),
            .cursor_char = '@',

            .screen = kernel_start_context.screen,
            .root_xsdt = kernel_start_context.root_xsdt,
            .mapped_memory = undefined,
            .next_free_virtual_address = kernel_start_context.next_free_virtual_address,
            .application_processor_contexts = kernel_start_context.application_processor_contexts,

            .usb_xhci_controllers = toolbox.RandomRemovalLinkedList(*usb_xhci.Controller).init(kernel_start_context.global_arena),

            .global_arena = kernel_start_context.global_arena,
            .frame_arena = toolbox.Arena.init_with_buffer(frame_arena_bytes),
            .scratch_arena = toolbox.Arena.init_with_buffer(scratch_arena_bytes),
        };
        g_state.mapped_memory = b: {
            var mapped_memory = toolbox.RandomRemovalLinkedList(w64.VirtualMemoryMapping).init(g_state.global_arena);
            for (kernel_start_context.mapped_memory) |mapping| {
                _ = mapped_memory.append(mapping);
            }
            break :b mapped_memory;
        };
        page_allocator.init(
            g_state.global_arena,
            &g_state.next_free_virtual_address,
            kernel_start_context.free_conventional_memory,
            &g_state.mapped_memory,
        );
        //TODO: remove
        g_state.frame_arena = toolbox.Arena.init(w64.KERNEL_FRAME_ARENA_SIZE);
        g_state.scratch_arena = toolbox.Arena.init(w64.KERNEL_SCRATCH_ARENA_SIZE);
    }
    //set up GDT
    set_up_gdt();

    //set up IDT
    set_up_idt();

    //set up memory map
    {
        //TODO

    }

    //bring processors in to kernel space
    {
        //TODO
    }

    //set up drivers
    {
        const pcie_devices = pcie.enumerate_devices(
            kernel_start_context.root_xsdt,
            g_state.global_arena,
            g_state.mapped_memory,
        );
        for (pcie_devices) |*dev| {
            switch (dev.header) {
                .EndPointDevice => |end_point_device_header| {
                    if (end_point_device_header.class_code == pcie.MASS_STORAGE_CLASS_CODE and
                        end_point_device_header.subclass_code == pcie.NVME_SUBCLASS_CODE)
                    {
                        const physical_bar0 = end_point_device_header.effective_bar0();
                        const nvme_bar0 = w64.physical_to_virtual(physical_bar0, g_state.mapped_memory) catch b: {
                            break :b w64.map_mmio_physical_address(
                                physical_bar0,
                                &g_state.next_free_virtual_address,
                                1,
                                g_state.global_arena,
                                &g_state.mapped_memory,
                            );
                        };

                        print_serial("Found NVMe drive! Virtual BAR0: {X}, Physical BAR0: {X}", .{ nvme_bar0, physical_bar0 });

                        //TODO:
                        // const nvme_device = nvme.init(dev, nvme_bar0) catch |e| {
                        //     //TODO specify the nvme device id
                        //     panic_fmt("Error initing NVMe device: {}", .{e});
                        // };

                        // const main_disk_serial_number = "osdisk";
                        // if (utils.are_slices_equal(nvme_device.serial_number[0..main_disk_serial_number.len], main_disk_serial_number)) {
                        //     osdisk_opt = nvme_device;
                        // }
                    } else if (end_point_device_header.class_code == pcie.SERIAL_BUS_CLASS_CODE and
                        end_point_device_header.subclass_code == pcie.USB_SUBCLASS_CODE)
                    {
                        switch (end_point_device_header.programming_interface_byte) {
                            pcie.EHCI_PROGRAMING_INTERFACE => {
                                //TODO
                                //const physical_bar0 = end_point_device_header.effective_bar0();
                                //const virtual_bar0 = kernel_memory.map_physical_pages_to_next_free_address(physical_bar0, 2) catch |e| {
                                //panic_fmt("Error mapping BAR0 address of USB EHCI controller {x}. Error: {} ", .{ end_point_device_header.bar0, e });
                                //};
                                //usb_ehci.init(virtual_bar0);
                            },
                            pcie.XHCI_PROGRAMING_INTERFACE => {
                                const physical_bar0 = end_point_device_header.effective_bar0();
                                print_serial("XCHI physical bar0: {X}", .{physical_bar0});
                                const virtual_bar0 = w64.physical_to_virtual(physical_bar0, g_state.mapped_memory) catch b: {
                                    break :b w64.map_mmio_physical_address(
                                        physical_bar0,
                                        &g_state.next_free_virtual_address,
                                        3,
                                        g_state.global_arena,
                                        &g_state.mapped_memory,
                                    );
                                };
                                print_serial("Found USB xHCI controller! Virtual BAR0: {X}, Physical BAR0: {X}", .{ virtual_bar0, physical_bar0 });
                                var usb_controller = usb_xhci.init(
                                    dev,
                                    virtual_bar0,
                                    g_state.scratch_arena,
                                    &g_state.mapped_memory,
                                ) catch |e| {
                                    toolbox.panic("Could not init xHCI adapter: {}", .{e});
                                };
                                _ = g_state.usb_xhci_controllers.append(usb_controller);

                                for (usb_controller.devices) |device| {
                                    if (!device.is_connected) {
                                        continue;
                                    }
                                    for (device.interfaces) |*interface| {
                                        switch (interface.class_data) {
                                            .HID => |hid_data| {
                                                usb_hid.init_hid_interface(
                                                    interface,
                                                    hid_data.hid_descriptor,
                                                    g_state.scratch_arena,
                                                    &g_state.mapped_memory,
                                                ) catch |e| {
                                                    //TODO: remove
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
                            },
                            else => {
                                print_serial("USB controller: {}", .{end_point_device_header});
                            },
                        }
                    }
                },
                .BridgeDevice => |_| {
                    //TODO
                },
                else => {
                    //TODO error handle
                },
            }
        }

        print_serial("PCIE devices len: {}", .{pcie_devices.len});
    }

    @memset(g_state.screen.back_buffer, .{ .data = 0 });

    echo_welcome_line("*** Wozmon64 ***\n", .{});
    {
        echo_welcome_line("{} bytes free *** {} processors free *** {} x {} pixels free\n", .{
            page_allocator.pages_free() * w64.MEMORY_PAGE_SIZE,
            g_state.application_processor_contexts.len,
            g_state.screen.width,
            g_state.screen.height,
        });
    }

    echo_str8("\\\n", .{});
    while (true) {
        var it = g_state.usb_xhci_controllers.iterator();
        while (it.next()) |controller_ptr| {
            const controller = controller_ptr.*;

            usb_hid.poll_events(controller.devices, controller.event_ring, &controller.event_response_map);
        }
        draw_cursor();
        @memcpy(g_state.screen.frame_buffer, g_state.screen.back_buffer);
    }

    toolbox.hang();
}
pub inline fn allocate_memory(n: usize) []u8 {
    return page_allocator.allocate(
        @divTrunc(toolbox.align_up(n, w64.MEMORY_PAGE_SIZE), w64.MEMORY_PAGE_SIZE),
    );
}

pub inline fn free_memory(data: []u8) void {
    page_allocator.free(data);
}

pub fn draw_cursor() void {
    //update cursor
    {
        const now = w64.now();
        if (now.sub(g_state.last_cursor_update).milliseconds() >= CURSOR_BLINK_TIME_MS) {
            g_state.last_cursor_update = now;
            g_state.cursor_char = if (g_state.cursor_char == '@') ' ' else '@';
        }
    }

    const index = g_state.cursor_char - ' ';
    const font = g_state.screen.font;
    const bitmap = font.character_bitmap(index);
    for (0..font.height) |y| {
        const screen_y = (g_state.cursor_y * font.height) + y;
        for (0..font.width) |x| {
            const screen_x = (g_state.cursor_x * font.kerning) + x;
            g_state.screen.back_buffer[screen_y * g_state.screen.stride + screen_x] =
                bitmap[y * font.width + x];
        }
    }
}
pub fn echo_welcome_line(comptime fmt: []const u8, args: anytype) void {
    const scratch_arena = g_state.scratch_arena;
    const arena_save_point = scratch_arena.create_save_point();
    defer scratch_arena.restore_save_point(arena_save_point);

    const str = toolbox.str8fmt(fmt, args, scratch_arena);

    toolbox.assert(
        g_state.screen.width_in_characters > str.rune_length,
        "Bad font scale. Try making it smaller",
        .{},
    );
    const padding_each_side = @divTrunc(g_state.screen.width_in_characters - str.rune_length, 2);
    const spaces = scratch_arena.push_slice(u8, padding_each_side);

    @memset(spaces, ' ');

    echo_str8("{s}{}{s}", .{ spaces, str, spaces });
    carriage_return();
}

pub fn echo_str8(comptime fmt: []const u8, args: anytype) void {
    const scratch_arena = g_state.scratch_arena;
    const arena_save_point = scratch_arena.create_save_point();
    defer scratch_arena.restore_save_point(arena_save_point);

    const to_print = toolbox.str8fmt(fmt, args, scratch_arena);

    var it = to_print.iterator();
    while (it.next()) |rune_and_length| {
        const rune = rune_and_length.rune;
        if (rune == '\r') {
            continue;
        }
        if (rune == '\n') {
            g_state.cursor_x = 0;
            carriage_return();
            continue;
        }
        var byte = if (rune >= ' ' and rune < 128)
            std.ascii.toUpper(@intCast(rune))
        else
            '?';
        if (byte > '_') {
            byte = '?';
        }

        //output char to serial
        if (comptime ENABLE_SERIAL) {
            asm volatile (
                \\mov $0x3F8, %%dx
                \\mov %[char], %%al
                \\outb %%al, %%dx
                :
                : [char] "r" (byte),
                : "rax", "rdx"
            );
        }

        const index = byte - ' ';

        const font = g_state.screen.font;
        const bitmap = font.character_bitmap(index);

        for (0..font.height) |y| {
            const screen_y = (g_state.cursor_y * font.height) + y;
            for (0..font.width) |x| {
                const screen_x = (g_state.cursor_x * font.kerning) + x;
                g_state.screen.back_buffer[screen_y * g_state.screen.stride + screen_x] =
                    bitmap[y * font.width + x];
            }
        }
        g_state.cursor_x += 1;
        if (g_state.cursor_x >= g_state.screen.width_in_characters) {
            carriage_return();
        }
    }
}

fn carriage_return() void {
    //output new line to serial
    if (comptime ENABLE_SERIAL) {
        asm volatile (
            \\mov $0x3F8, %%dx
            \\mov $'\n', %%al
            \\outb %%al, %%dx
            ::: "rax", "rdx");
    }

    g_state.cursor_x = 0;
    g_state.cursor_y += 1;
    const font = g_state.screen.font;
    const height_in_characters = g_state.screen.height_in_characters;
    if (g_state.cursor_y >= height_in_characters) {
        for (0..g_state.screen.height_in_characters - 1) |cy| {
            const srcy = (cy + 1) * font.height;
            const desty = cy * font.height;
            const src = g_state.screen.back_buffer[srcy * g_state.screen.stride .. (srcy + font.height - 1) * g_state.screen.stride +
                g_state.screen.width];
            const dest = g_state.screen.back_buffer[desty * g_state.screen.stride .. (desty + font.height - 1) * g_state.screen.stride +
                g_state.screen.width];
            @memcpy(dest, src);
        }
        {
            const y = (height_in_characters - 1) * font.height;
            const to_blank = g_state.screen.back_buffer[y * g_state.screen.stride ..];
            @memset(to_blank, .{ .data = 0 });
        }
        g_state.cursor_y = height_in_characters - 1;
    }
}

fn set_up_gdt() void {
    //TODO
    const gdt_array = [3]amd64.GDTDescriptor{
        //null descriptor
        @bitCast(@as(u64, 0)),
        //code descriptor
        .{
            .segment_limit_bits_0_to_15 = 0xFFFF,
            .base_addr_bits_0_to_23 = 0,
            .type_bits = @intFromEnum(amd64.GDTDescriptorType.ExecuteRead),
            .is_not_system_segment = true,
            .privilege_bits = 0,
            .is_present = true,
            .segment_limit_bits_16_to_19 = 0xF,
            .is_for_long_mode_code = true,
            .is_big = false,
            .is_granular = true,
            .base_addr_bits_24_to_31 = 0,
        },
        //data segment
        .{
            .segment_limit_bits_0_to_15 = 0xFFFF,
            .base_addr_bits_0_to_23 = 0,
            .type_bits = @intFromEnum(amd64.GDTDescriptorType.ReadWrite),
            .is_not_system_segment = true,
            .privilege_bits = 0,
            .is_present = true,
            .segment_limit_bits_16_to_19 = 0xF,
            .is_for_long_mode_code = false,
            .is_big = true,
            .is_granular = true,
            .base_addr_bits_24_to_31 = 0,
        },
    };
    const gdt = g_state.global_arena.push_slice(amd64.GDTDescriptor, gdt_array.len);
    @memcpy(gdt, gdt_array[0..]);

    const gdt_register = amd64.GDTRegister{
        .limit = @sizeOf(@TypeOf(gdt_array)) - 1,
        .gdt = gdt.ptr,
    };
    var ljmp_operand: [16]u8 = undefined;
    asm volatile (
        \\lgdt (%[gdtr])
        \\movw $0x10, %%ax
        \\movw %%ax, %%ds
        \\movw %%ax, %%es
        \\movw %%ax, %%ss
        \\movw $0, %%ax
        \\movw %%ax, %%fs #TODO: TLS
        \\movw %%ax, %%gs
        \\pushq $8
        \\lea .long_jump(%%rip), %%rax
        \\pushq %%rax
        \\lretq
        \\.long_jump:
        :
        : [limit] "r" (gdt_register.limit),
          [gdt] "r" (@intFromPtr(gdt_register.gdt)),
          [gdtr] "r" (&gdt_register),
          [ljmp_operand] "r" (&ljmp_operand),
        : "rax"
    );
}

fn set_up_idt() void {
    var idt = g_state.global_arena.push_slice_clear(amd64.IDTDescriptor, 256);
    const idt_register = amd64.IDTRegister{
        .limit = @intCast(idt.len - 1),
        .idt = idt.ptr,
    };
    amd64.register_exception_handler(&page_fault_handler, .PageFault, idt);
    amd64.register_exception_handler(&invalid_opcode_handler, .InvalidOpcode, idt);
    asm volatile (
        \\lidt (%[idtr])
        :
        : [idtr] "r" (&idt_register),
    );
}

fn invalid_opcode_handler() callconv(.Interrupt) void {
    toolbox.panic("Invalid opcode!", .{});
}
const ExceptionRegisters = packed struct {
    error_code: u64,
    return_rip: u64,
    return_cs: u64,
    return_rflags: u64,
    return_rsp: u64,
    return_ss: u64,
};

comptime {
    const SAVE_FRAME_POINTER = if (toolbox.IS_DEBUG)
        \\push %rbp
        \\mov %rsp, %rbp
    else
        "";
    asm (
        \\.global page_fault_handler
        \\.extern page_fault_handler_inner
        \\page_fault_handler:
        \\
        \\#TODO: save all registers
        \\mov (%rsp), %rdi #save error code
        \\add $8,%rsp
        \\mov %cr2, %rsi
        \\
        ++ SAVE_FRAME_POINTER ++
            \\
            \\call page_fault_handler_inner
    );
}

extern fn page_fault_handler() void;

export fn page_fault_handler_inner(error_code: u64, unmapped_address: u64) callconv(.C) void {
    //return address should have something likeFFFFFFFF80008D70
    toolbox.panic(
        "Page fault! Error code: {}, Unmapped address: {X}",
        .{
            error_code,
            unmapped_address,
        },
    );

    //TODO as of now, we cannot return since we destroy all registers
}

//for debugging within print routines
pub fn print_serial(comptime fmt: []const u8, args: anytype) void {
    const scratch_arena = g_state.scratch_arena;
    const arena_save_point = scratch_arena.create_save_point();
    defer scratch_arena.restore_save_point(arena_save_point);
    const to_print = toolbox.str8fmt(fmt, args, scratch_arena);

    for (to_print.bytes) |byte| {
        asm volatile (
            \\mov $0x3F8, %%dx
            \\mov %[char], %%al
            \\outb %%al, %%dx
            :
            : [char] "r" (byte),
            : "rax", "rdx"
        );
    }
    asm volatile (
        \\mov $0x3F8, %%dx
        \\mov %[char], %%al
        \\outb %%al, %%dx
        :
        : [char] "r" (@as(u8, '\n')),
        : "rax", "rdx"
    );
}

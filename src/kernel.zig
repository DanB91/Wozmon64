//Copyright Daniel Bokser 2023
//See LICENSE file for permissible source code usage
pub const w64 = @import("wozmon64.zig");

const std = @import("std");
const toolbox = @import("toolbox");
const profiler = toolbox.profiler;
const kernel_memory = @import("kernel_memory.zig");
const amd64 = @import("amd64.zig");
const pcie = @import("drivers/pcie.zig");
const usb_xhci = @import("drivers/usb_xhci.zig");
const usb_hid = @import("drivers/usb_hid.zig");
const commands = @import("commands.zig");
const programs = @import("programs.zig");

pub const THIS_PLATFORM = toolbox.Platform.Wozmon64;
pub const ENABLE_PROFILER = true;

const CURSOR_BLINK_TIME_MS = 500;
const ENABLE_SERIAL = toolbox.IS_DEBUG;

//userspace functions
pub fn echo(bytes: [*c]u8, len: u64) callconv(.C) void {
    const str = toolbox.str8(bytes[0..len]);
    echo_fmt("{}", .{str});
}

const KernelState = struct {
    cursor_x: usize,
    cursor_y: usize,
    last_cursor_update: w64.Time,
    cursor_char: toolbox.Rune,

    screen: w64.Screen,
    root_xsdt: *const amd64.XSDT,
    application_processor_contexts: []*w64.ApplicationProcessorKernelContext,

    apic_address: u64,
    usb_xhci_controllers: toolbox.RandomRemovalLinkedList(*usb_xhci.Controller),
    input_state: w64.InputState,
    are_characters_shifted: bool,
    debug_symbols: std.dwarf.DwarfInfo,

    global_arena: *toolbox.Arena,
    frame_arena: *toolbox.Arena,
    scratch_arena: *toolbox.Arena,

    //monitor state
    rune_buffer: []toolbox.Rune,
    command_buffer: toolbox.DynamicArray(u8),
    opened_address: u64,

    //runtime "constants"
    screen_pixel_width: *u64,
    screen_pixel_height: *u64,
    frame_buffer_size: *u64,
    frame_buffer_stride: *u64,

    //profiler state
    show_profiler: bool,
};

const StackUnwinder = struct {
    fp: u64,
    i: usize = 0,
    max_iterations: usize = 10,

    fn init() StackUnwinder {
        return .{
            .fp = @frameAddress(),
        };
    }
    fn next(self: *StackUnwinder) ?u64 {
        defer self.i += 1;
        if (self.i >= self.max_iterations or self.fp == 0 or !toolbox.is_aligned_to(self.fp, @alignOf(u64))) {
            return null;
        }
        const ip = @as(*const u64, @ptrFromInt(self.fp + @sizeOf(u64))).*;
        const new_fp = @as(*const u64, @ptrFromInt(self.fp)).*;
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

    echo_line("{s}", .{msg});
    var it = StackUnwinder.init();
    const debug_symbols = &g_state.debug_symbols;
    const global_allocator = g_state.global_arena.zstd_allocator;
    while (it.next()) |address| {
        const compile_unit = debug_symbols.findCompileUnit(address) catch |e| {
            echo_line("At {X} CompileUnit error: {}", .{ address, e });
            continue;
        };
        const line_info = debug_symbols.getLineNumberInfo(
            global_allocator,
            compile_unit.*,
            address - 1,
        ) catch |e| {
            echo_line("At {X} Line info Error: {}", .{ address, e });
            continue;
        };
        echo_line("At {s}:{}:{} -- {?s}: 0x{X}", .{
            line_info.file_name,
            line_info.line,
            line_info.column,
            debug_symbols.getSymbolName(address),
            address,
        });
    }
    render();
    toolbox.hang();
}

var g_state: KernelState = undefined;

export fn kernel_entry(kernel_start_context: *w64.KernelStartContext) callconv(.C) noreturn {
    @setAlignStack(256);
    {
        const vtable: *std.mem.Allocator.VTable =
            @ptrFromInt(@intFromPtr(kernel_start_context.global_arena.zstd_allocator.vtable));
        vtable.* = toolbox.Arena.ZSTD_VTABLE;
    }
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
            .application_processor_contexts = undefined,

            .apic_address = 0,
            .input_state = w64.InputState.init(kernel_start_context.global_arena),
            .usb_xhci_controllers = toolbox.RandomRemovalLinkedList(*usb_xhci.Controller).init(kernel_start_context.global_arena),
            .are_characters_shifted = false,
            .debug_symbols = undefined,

            .show_profiler = false,

            .command_buffer = toolbox.DynamicArray(u8).init(
                kernel_start_context.global_arena,
                kernel_start_context.screen.width_in_runes * kernel_start_context.screen.height_in_runes,
            ),
            .opened_address = 0,
            .rune_buffer = kernel_start_context.global_arena.push_slice(
                toolbox.Rune,
                kernel_start_context.screen.height_in_runes * kernel_start_context.screen.width,
            ),

            .global_arena = kernel_start_context.global_arena,
            .frame_arena = toolbox.Arena.init_with_buffer(frame_arena_bytes),
            .scratch_arena = toolbox.Arena.init_with_buffer(scratch_arena_bytes),

            .screen_pixel_height = @ptrFromInt(w64.SCREEN_PIXEL_HEIGHT_ADDRESS),
            .screen_pixel_width = @ptrFromInt(w64.SCREEN_PIXEL_WIDTH_ADDRESS),
            .frame_buffer_size = @ptrFromInt(w64.FRAME_BUFFER_SIZE_ADDRESS),
            .frame_buffer_stride = @ptrFromInt(w64.FRAME_BUFFER_STRIDE_ADDRESS),
        };
        const debug_symbols = parse_elf_debug_symbols(
            kernel_start_context.kernel_elf_bytes,
            kernel_start_context.global_arena,
        ) catch |e| {
            print_serial("failed to parse debug symbols: {}", .{e});
            toolbox.hang();
        };
        g_state.debug_symbols = debug_symbols;
        const mapped_memory = b: {
            var mapped_memory = toolbox.RandomRemovalLinkedList(w64.VirtualMemoryMapping).init(g_state.global_arena);
            for (kernel_start_context.mapped_memory) |mapping| {
                _ = mapped_memory.append(mapping);
            }
            break :b mapped_memory;
        };
        kernel_memory.init(
            g_state.global_arena,
            kernel_start_context.next_free_virtual_address,
            kernel_start_context.free_conventional_memory,
            mapped_memory,
        );
        //TODO: remove
        g_state.frame_arena = toolbox.Arena.init(w64.KERNEL_FRAME_ARENA_SIZE);
        g_state.scratch_arena = toolbox.Arena.init(w64.KERNEL_SCRATCH_ARENA_SIZE);
    }
    profiler.init(g_state.global_arena);
    //set up GDT
    set_up_gdt(g_state.global_arena);

    //set up IDT
    set_up_idt(g_state.global_arena);

    //map APIC
    {
        g_state.apic_address = kernel_memory.map_mmio_physical_address(
            amd64.rdmsr(amd64.IA32_APIC_BASE_MSR) &
                toolbox.mask_for_bit_range(12, 63, u64),
            1,
            g_state.global_arena,
        );
    }
    //bring processors in to kernel space
    {
        g_state.application_processor_contexts = g_state.global_arena.push_slice(
            *w64.ApplicationProcessorKernelContext,
            kernel_start_context.application_processor_contexts.len,
        );

        for (kernel_start_context.application_processor_contexts, 0..) |context, i| {
            const stack = g_state.global_arena.push_slice_clear_aligned(
                u8,
                w64.MEMORY_PAGE_SIZE,
                w64.MEMORY_PAGE_SIZE,
            );
            const thread_local_storage = g_state.global_arena.push_slice_clear_aligned(
                u8,
                w64.MEMORY_PAGE_SIZE,
                w64.MEMORY_PAGE_SIZE,
            );
            const ap_kernel_context = g_state.global_arena.push_clear_aligned(
                w64.ApplicationProcessorKernelContext,
                w64.MEMORY_PAGE_SIZE,
            );
            const rsp = @intFromPtr(stack.ptr);
            const cr3: u64 =
                asm volatile ("mov %%cr3, %[cr3]"
                : [cr3] "=r" (-> u64),
            );
            ap_kernel_context.* = .{
                .cr3 = cr3,
                .rsp = rsp,
                .fsbase = @intFromPtr(thread_local_storage.ptr),
                .gsbase = @intFromPtr(ap_kernel_context),
                .processor_id = context.processor_id,
                .job = .{ .value = null },
            };
            context.application_processor_kernel_entry_data.set(.{
                .start_context_data = ap_kernel_context,
                .entry = core_entry,
                .cr3 = cr3,
                .rsp = rsp,
            });
            g_state.application_processor_contexts[i] = ap_kernel_context;
        }
    }

    //set up drivers
    {
        const pcie_devices = pcie.enumerate_devices(
            kernel_start_context.root_xsdt,
            g_state.global_arena,
        );
        for (pcie_devices) |*dev| {
            switch (dev.header) {
                .EndPointDevice => |end_point_device_header| {
                    if (end_point_device_header.class_code == pcie.MASS_STORAGE_CLASS_CODE and
                        end_point_device_header.subclass_code == pcie.NVME_SUBCLASS_CODE)
                    {
                        const physical_bar0 = end_point_device_header.effective_bar0();
                        print_serial("physical address: {X}", .{physical_bar0});
                        const nvme_bar0 = kernel_memory.physical_to_virtual(physical_bar0) catch b: {
                            break :b kernel_memory.map_mmio_physical_address(
                                physical_bar0,
                                1,
                                g_state.global_arena,
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
                                const virtual_bar0 = kernel_memory.physical_to_virtual(physical_bar0) catch b: {
                                    break :b kernel_memory.map_mmio_physical_address(
                                        physical_bar0,
                                        3,
                                        g_state.global_arena,
                                    );
                                };
                                print_serial("Found USB xHCI controller! Virtual BAR0: {X}, Physical BAR0: {X}", .{ virtual_bar0, physical_bar0 });
                                var usb_controller = usb_xhci.init(
                                    dev,
                                    virtual_bar0,
                                    g_state.scratch_arena,
                                ) catch |e| {
                                    toolbox.panic("Could not init xHCI adapter: {}", .{e});
                                };
                                _ = g_state.usb_xhci_controllers.append(usb_controller);

                                var it = usb_controller.devices.iterator();
                                while (it.next_value()) |device| {
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

    //populate runtime constants
    {
        g_state.screen_pixel_width.* = g_state.screen.width;
        g_state.screen_pixel_height.* = g_state.screen.height;
        g_state.frame_buffer_size.* = g_state.screen.frame_buffer.len;
        g_state.frame_buffer_stride.* = g_state.screen.stride;
    }

    echo_welcome_line("*** Wozmon64 ***\n", .{});
    {
        echo_welcome_line("{} bytes free *** {} processors free *** {} x {} pixels free\n", .{
            kernel_memory.pages_free() * w64.MEMORY_PAGE_SIZE,
            g_state.application_processor_contexts.len,
            g_state.screen.width,
            g_state.screen.height,
        });
    }

    echo_line("\\", .{});
    main_loop();

    toolbox.hang();
}

threadlocal var fbase_tls: usize = 0;
fn core_entry(context: *w64.ApplicationProcessorKernelContext) callconv(.C) noreturn {
    //TODO some bug is preventing this from working on desktop.  There might be
    //     some sort of race condition.  Debug
    //     Get debug symbols working first
    // const arena = toolbox.Arena.init(w64.MEMORY_PAGE_SIZE);

    var arena_buffer: [toolbox.kb(512)]u8 = undefined;
    const arena = toolbox.Arena.init_with_buffer(&arena_buffer);

    set_up_gdt(arena);
    set_up_idt(arena);
    asm volatile (
        \\wrfsbase %[fsbase]
        \\wrgsbase %[gsbase]
        :
        : [fsbase] "r" (context.fsbase),
          [gsbase] "r" (context.gsbase),
    );
    //print_serial("APIC register {X}", .{amd64.rdmsr(amd64.IA32_APIC_BASE_MSR)});
    fbase_tls = context.fsbase;
    print_apic_id_and_core_id();

    while (true) {
        if (context.job.get()) |job| {
            job.entry(job.user_data);
            context.job.set(null);
        }
        std.atomic.spinLoopHint();
    }
}
pub inline fn allocate_memory(n: usize) []u8 {
    return kernel_memory.allocate(
        @divTrunc(toolbox.align_up(n, w64.MEMORY_PAGE_SIZE), w64.MEMORY_PAGE_SIZE),
    );
}

pub inline fn free_memory(data: []u8) void {
    kernel_memory.free(data);
}

fn parse_elf_debug_symbols(kernel_elf: []const u8, arena: *toolbox.Arena) !std.dwarf.DwarfInfo {
    var section_store = toolbox.DynamicArray(std.elf.Elf64_Shdr).init(arena, 64);
    const header = b: {
        var kernel_image_byte_stream = std.io.fixedBufferStream(kernel_elf);
        var header = std.elf.Header.read(&kernel_image_byte_stream) catch {
            return error.ErrorParsingHeader;
        };
        var it = header.section_header_iterator(&kernel_image_byte_stream);

        while (it.next() catch null) |section| {
            section_store.append(section);
        }
        break :b header;
    };

    const sections = section_store.items();
    const shstrhdr = sections[header.shstrndx];
    const shstr = kernel_elf[shstrhdr.sh_offset .. shstrhdr.sh_offset + shstrhdr.sh_size];

    const debug_section_names = [_][]const u8{
        ".debug_info",
        ".debug_abbrev",
        ".debug_str",
        ".debug_str_offsets",
        ".debug_line",
        ".debug_line_str",
        ".debug_ranges",
        ".debug_loclists",
        ".debug_rnglists",
        ".debug_addr",
        ".debug_names",
        ".debug_frame",
        ".eh_frame",
        ".eh_frame_hdr",
    };

    var debug_sections = std.dwarf.DwarfInfo.null_section_array;
    for (sections) |section| {
        const namez = @as([*:0]const u8, @ptrCast(shstr.ptr + section.sh_name));
        const name = std.mem.span(namez);
        for (debug_section_names, 0..) |debug_section_name, i| {
            if (std.mem.eql(u8, debug_section_name, name)) {
                debug_sections[i] = .{
                    .data = kernel_elf[section.sh_offset .. section.sh_offset + section.sh_size],
                    .owned = false,
                };
            }
        }
    }
    var debug_info = std.dwarf.DwarfInfo{
        .endian = header.endian,
        .sections = debug_sections,
        .is_macho = false,
    };
    std.dwarf.openDwarfDebugInfo(
        &debug_info,
        arena.zstd_allocator,
    ) catch {
        return error.ErrorOpeningDwarfDebugInfo;
    };

    return debug_info;
}

pub fn echo_welcome_line(comptime fmt: []const u8, args: anytype) void {
    const scratch_arena = g_state.scratch_arena;
    const arena_save_point = scratch_arena.create_save_point();
    defer scratch_arena.restore_save_point(arena_save_point);

    const str = toolbox.str8fmt(fmt, args, scratch_arena);

    toolbox.assert(
        g_state.screen.width_in_runes > str.rune_length,
        "Bad font scale. Try making it smaller",
        .{},
    );
    const padding_each_side = @divTrunc(g_state.screen.width_in_runes - str.rune_length, 2);
    const spaces = scratch_arena.push_slice(u8, padding_each_side);

    @memset(spaces, ' ');

    echo_fmt("{s}{}{s}", .{ spaces, str, spaces });
    carriage_return();
}
pub inline fn echo_line(comptime fmt: []const u8, args: anytype) void {
    echo_fmt(fmt ++ "\n", args);
}

pub fn echo_fmt(comptime fmt: []const u8, args: anytype) void {
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

        g_state.rune_buffer[
            g_state.cursor_y * g_state.screen.width_in_runes +
                g_state.cursor_x
        ] =
            byte;

        g_state.cursor_x += 1;
        if (g_state.cursor_x >= g_state.screen.width_in_runes) {
            carriage_return();
        }
    }
}

noinline fn set_up_gdt(arena: *toolbox.Arena) void {
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
        // //FS segment
        // .{
        //     .segment_limit_bits_0_to_15 = 0xFFFF,
        //     .base_addr_bits_0_to_23 = 0,
        //     .type_bits = @intFromEnum(amd64.GDTDescriptorType.ReadWrite),
        //     .is_not_system_segment = true,
        //     .privilege_bits = 0,
        //     .is_present = true,
        //     .segment_limit_bits_16_to_19 = 0xF,
        //     .is_for_long_mode_code = false,
        //     .is_big = true,
        //     .is_granular = true,
        //     .base_addr_bits_24_to_31 = 0,
        // },
    };
    const gdt = arena.push_slice(amd64.GDTDescriptor, gdt_array.len);
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
        \\movw %%ax, %%fs 
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

fn set_up_idt(arena: *toolbox.Arena) void {
    var idt = arena.push_slice_clear(amd64.IDTDescriptor, 256);
    const idt_register = amd64.IDTRegister{
        .limit = @intCast(idt.len - 1),
        .idt = idt.ptr,
    };
    amd64.register_exception_handler(&page_fault_handler, .PageFault, idt);
    amd64.register_exception_handler(&invalid_opcode_handler, .InvalidOpcode, idt);
    amd64.register_exception_handler(&nmi_handler, .NMI, idt);
    asm volatile (
        \\lidt (%[idtr])
        :
        : [idtr] "r" (&idt_register),
    );
}
fn nmi_handler() callconv(.Interrupt) void {
    const processor_context = get_processor_context();

    processor_context.job.set(null);
    asm volatile (
        \\movq %[ksc_addr], %%rdi
        \\
        \\pushq $0x10 #SS
        \\pushq %[stack_virtual_address]
        \\pushfq
        \\pushq $0x8 #CS
        \\pushq %[entry_point]
        \\iretq
        \\ud2 #this instruction is for searchability in the disassembly
        :
        :
        //TODO no idea why i have to subtract 8 here.  If I don't I get SSE alignment errors
          [stack_virtual_address] "r" (processor_context.rsp - 8),
          [ksc_addr] "r" (@intFromPtr(processor_context)),
          [entry_point] "r" (@intFromPtr(&core_entry)),
        : "rdi"
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
        \\
        \\mov %rsp, %rbp
        \\
    else
        \\
        \\
        ;

    asm (
        \\.global page_fault_handler
        \\.extern page_fault_handler_inner
        \\page_fault_handler:
        \\
        \\xchg %rdi, (%rsp) #save and pop error code
        \\push %rbp
        ++ SAVE_FRAME_POINTER ++
            \\push %rsi
            \\push %rax
            \\push %rbx
            \\push %rcx
            \\push %rdx
            \\push %r8
            \\push %r9
            \\push %r10
            \\push %r11
            \\push %r12
            \\push %r13
            \\push %r14
            \\push %r15
            \\sub $0x100, %rsp
            \\movdqu %xmm15, 0xF0(%rsp)
            \\movdqu %xmm14, 0xE0(%rsp)
            \\movdqu %xmm13, 0xD0(%rsp)
            \\movdqu %xmm12, 0xC0(%rsp)
            \\movdqu %xmm11, 0xB0(%rsp)
            \\movdqu %xmm10, 0xC0(%rsp)
            \\movdqu %xmm9, 0x90(%rsp)
            \\movdqu %xmm8, 0x80(%rsp)
            \\movdqu %xmm7, 0x70(%rsp)
            \\movdqu %xmm6, 0x60(%rsp)
            \\movdqu %xmm5, 0x50(%rsp)
            \\movdqu %xmm4, 0x40(%rsp)
            \\movdqu %xmm3, 0x30(%rsp)
            \\movdqu %xmm2, 0x20(%rsp)
            \\movdqu %xmm1, 0x10(%rsp)
            \\movdqu %xmm0, 0x0(%rsp)
            \\
            \\mov %cr2, %rsi
            \\
            \\
            \\call page_fault_handler_inner
            \\
            \\
            \\movdqu 0(%rsp), %xmm15 
            \\movdqu 0x10(%rsp), %xmm14
            \\movdqu 0x20(%rsp), %xmm13
            \\movdqu 0x30(%rsp), %xmm12
            \\movdqu 0x40(%rsp), %xmm11
            \\movdqu 0x50(%rsp), %xmm10
            \\movdqu 0x60(%rsp), %xmm9 
            \\movdqu 0x70(%rsp), %xmm8 
            \\movdqu 0x80(%rsp), %xmm7 
            \\movdqu 0x90(%rsp), %xmm6 
            \\movdqu 0xA0(%rsp), %xmm5 
            \\movdqu 0xB0(%rsp), %xmm4 
            \\movdqu 0xC0(%rsp), %xmm3 
            \\movdqu 0xD0(%rsp), %xmm2 
            \\movdqu 0xE0(%rsp), %xmm1 
            \\movdqu 0xF0(%rsp), %xmm0 
            \\add $0x100, %rsp
            \\pop %r15
            \\pop %r14
            \\pop %r13
            \\pop %r12
            \\pop %r11
            \\pop %r10
            \\pop %r9
            \\pop %r8
            \\pop %rdx
            \\pop %rcx
            \\pop %rbx
            \\pop %rax
            \\pop %rsi
            \\pop %rbp
            \\pop %rdi
            \\iretq
    );
}

extern fn page_fault_handler() void;

export fn page_fault_handler_inner(error_code: u64, unmapped_address: u64) callconv(.C) void {
    _ = error_code;
    const to_map = toolbox.align_down(unmapped_address, w64.MEMORY_PAGE_SIZE);
    if (to_map == 0) {
        toolbox.panic("Allocating memory at null page! Address: {X}", .{unmapped_address});
    }
    print_serial("Allocating page for address: {X}", .{to_map});
    var it = StackUnwinder.init();
    while (it.next()) |address| {
        print_serial("At {X}", .{address});
    }

    //TODO: remove
    const page = kernel_memory.allocate_at_address(to_map, 1);
    // print_serial("Page virtual address: {X}", .{@intFromPtr(page.ptr)});
    for (page) |*b| {
        b.* = 0xAA;
    }

    // //return address should have something like FFFFFFFF80008D70
    // toolbox.panic(
    //     "Page fault! Error code: {}, Unmapped address: {X}",
    //     .{
    //         error_code,
    //         unmapped_address,
    //     },
    // );
}

//for debugging within print routines
pub fn print_serial(comptime fmt: []const u8, args: anytype) void {
    if (comptime !ENABLE_SERIAL) {
        return;
    }

    const StaticVars = struct {
        var print_lock: w64.ReentrantTicketLock = .{};
    };
    StaticVars.print_lock.lock();
    defer StaticVars.print_lock.release();

    const to_print = toolbox.str8fmtbuf(fmt, args, 2048);

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

fn main_loop() void {
    while (true) {
        profiler.start_profiler();

        {
            profiler.begin("Poll USB controllers");
            defer profiler.end();

            var it = g_state.usb_xhci_controllers.iterator();
            while (it.next_value()) |controller| {
                profiler.begin("Poll XHCI controller");
                const should_poll_hid = usb_xhci.poll_controller(controller);
                profiler.end();

                if (should_poll_hid) {
                    profiler.begin("Poll USB HID");
                    usb_hid.poll(
                        controller,
                        &g_state.input_state,
                    );
                    profiler.end();
                }
            }
        }
        while (g_state.input_state.modifier_key_pressed_events.dequeue()) |scancode| {
            switch (scancode) {
                .LeftShift, .RightShift => {
                    g_state.are_characters_shifted = true;
                },
                else => {},
            }
        }
        while (g_state.input_state.modifier_key_released_events.dequeue()) |scancode| {
            switch (scancode) {
                .LeftShift, .RightShift => {
                    g_state.are_characters_shifted = false;
                },
                else => {},
            }
        }
        profiler.begin("Key pressed events");
        while (g_state.input_state.key_pressed_events.dequeue()) |scancode| {
            switch (scancode) {
                .F1 => type_program(programs.woz_and_jobs),
                .F2 => g_state.show_profiler = !g_state.show_profiler,
                else => type_key(scancode, g_state.are_characters_shifted),
            }
        }
        profiler.end();

        profiler.begin("Key released events");
        while (g_state.input_state.key_released_events.dequeue()) |scancode| {
            _ = scancode;
        }
        profiler.end();

        blink_cursor();

        render();
    }
}
fn render() void {
    profiler.begin("Clear back buffer");
    @memset(g_state.screen.back_buffer, .{ .data = 0 });
    profiler.end();
    profiler.end_profiler();

    if ((comptime ENABLE_PROFILER) and g_state.show_profiler) {
        draw_profiler();
    } else {
        draw_runes();
        draw_cursor();
    }

    @memcpy(g_state.screen.frame_buffer, g_state.screen.back_buffer);
}

fn draw_profiler() void {
    if (comptime !ENABLE_PROFILER) {
        return;
    }

    const save_point = g_state.scratch_arena.create_save_point();
    defer g_state.scratch_arena.restore_save_point(save_point);
    var profiler_it = profiler.line_iterator(g_state.scratch_arena);

    var rune_y: usize = 0;
    while (profiler_it.next()) |line| {
        var rune_x: usize = 0;
        var it = line.iterator();
        while (it.next()) |rune_and_length| {
            draw_rune(rune_and_length.rune, rune_x, rune_y);
            rune_x += 1;
        }
        rune_y += 1;
    }
}

fn draw_runes() void {
    var rune_x: usize = 0;
    var rune_y: usize = 0;
    for (g_state.rune_buffer) |c| {
        draw_rune(c, rune_x, rune_y);

        rune_x += 1;
        if (rune_x >= g_state.screen.width_in_runes) {
            rune_x = 0;
            rune_y += 1;
        }
    }
}
fn draw_rune(rune: toolbox.Rune, rune_x: usize, rune_y: usize) void {
    const r = switch (rune) {
        'a'...'z' => rune - 32,
        else => rune,
    };
    if (r < ' ' or r > '_') {
        return;
    }
    const index = @as(u8, @intCast(r)) - ' ';
    const font = g_state.screen.font;
    const bitmap = font.character_bitmap(index);
    for (0..font.height) |y| {
        const screen_y = (rune_y * font.height) + y;
        for (0..font.width) |x| {
            const screen_x = (rune_x * font.kerning) + x;
            g_state.screen.back_buffer[screen_y * g_state.screen.stride + screen_x] =
                bitmap[y * font.width + x];
        }
    }
}

fn blink_cursor() void {
    profiler.begin("blink cursor");
    defer profiler.end();
    const now = w64.now();
    if (now.sub(g_state.last_cursor_update).milliseconds() >= CURSOR_BLINK_TIME_MS) {
        g_state.last_cursor_update = now;
        g_state.cursor_char = if (g_state.cursor_char == '@') ' ' else '@';
    }
}

fn draw_cursor() void {
    draw_rune(g_state.cursor_char, g_state.cursor_x, g_state.cursor_y);
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
    // const font = g_state.screen.font;
    const height_in_runes = g_state.screen.height_in_runes;
    if (g_state.cursor_y >= height_in_runes) {
        const width_in_runes = g_state.screen.width_in_runes;
        for (0..height_in_runes - 1) |row| {
            const dest_start = row * width_in_runes;
            const src_start = (row + 1) * width_in_runes;
            const dest = g_state.rune_buffer[dest_start .. dest_start + width_in_runes];
            const src = g_state.rune_buffer[src_start .. src_start + width_in_runes];
            @memcpy(dest, src);
        }
        //clear final row
        const dest_start = (height_in_runes - 1) * width_in_runes;
        @memset(g_state.rune_buffer[dest_start .. dest_start + width_in_runes], ' ');
        g_state.cursor_y = height_in_runes - 1;
    }
}
fn type_program(program: []const u8) void {
    const load_address: u32 = 0x230_0000;
    const dest = @as([*]u8, @ptrFromInt(load_address))[0..program.len];
    @memcpy(dest, program);
    echo_line("Loaded program to address {X}!", .{load_address});
    type_number(load_address);
    type_key(.Slash, false);
    type_number(@as(u32, 16));
    type_key(.Enter, false);
    type_number(load_address);
    type_key(.R, false);

    // type_number(@as(u32, 0x230_0000));
    // type_key(.Semicolon, true);
    // type_key(.Space, false);
    // for (program) |b| {
    //     type_number(b);
    //     type_key(.Space, false);
    // }
}

fn type_number(number: anytype) void {
    const number_of_bits: i32 = @bitSizeOf(@TypeOf(number));
    var shift = number_of_bits - 4;
    while (shift >= 0) : (shift -= 4) {
        type_nibble(@intCast((number >> @intCast(shift)) & 0xF));
    }
}
fn type_nibble(nibble: u8) void {
    const to_type: w64.ScanCode = switch (nibble) {
        0 => .Zero,
        1 => .One,
        2 => .Two,
        3 => .Three,
        4 => .Four,
        5 => .Five,
        6 => .Six,
        7 => .Seven,
        8 => .Eight,
        9 => .Nine,
        0xA => .A,
        0xB => .B,
        0xC => .C,
        0xD => .D,
        0xE => .E,
        0xF => .F,
        else => unreachable,
    };
    type_key(to_type, false);
}
fn type_key(scancode: w64.ScanCode, are_characters_shifted: bool) void {
    switch (scancode) {
        .LeftArrow, .Backspace => {
            if (g_state.cursor_x > 0) {
                g_state.cursor_x -= 1;
                g_state.rune_buffer[g_state.cursor_y * g_state.screen.width_in_runes + g_state.cursor_x] =
                    ' ';
            }
            _ = g_state.command_buffer.remove_last();
        },
        .A,
        .B,
        .C,
        .D,
        .E,
        .F,
        .G,
        .H,
        .I,
        .J,
        .K,
        .L,
        .M,
        .N,
        .O,
        .P,
        .Q,
        .R,
        .S,
        .T,
        .U,
        .V,
        .W,
        .X,
        .Y,
        .Z,

        .Zero,
        .One,
        .Two,
        .Three,
        .Four,
        .Five,
        .Six,
        .Seven,
        .Eight,
        .Nine,
        .Space,

        .Slash,
        .Backslash,
        .LeftBracket,
        .RightBracket,
        .Equals,
        .Backtick,
        .Hyphen,
        .Semicolon,
        .Quote,
        .Comma,
        .Period,
        => {
            const char = if (are_characters_shifted)
                w64.scancode_to_ascii_shifted(scancode)
            else
                w64.scancode_to_ascii(scancode);
            echo_fmt("{c}", .{char});

            _ = g_state.command_buffer.append(char);
        },
        .Enter => {
            echo_line("", .{});
            const parse_result =
                commands.parse_command(
                g_state.command_buffer.items(),
                g_state.scratch_arena,
            );
            defer g_state.scratch_arena.reset();
            handle_parse_result(parse_result, g_state.command_buffer.items());

            g_state.command_buffer.clear();
        },
        else => {},
    }
}

fn handle_command(command: commands.Command) void {
    switch (command) {
        .None => {},
        .Read => |arguments| {
            read_memory(
                arguments.from,
                arguments.to,
                arguments.number_of_bytes,
            );
        },
        .Write => |arguments| {
            handle_address_wrap_around(arguments.start, arguments.data.len) catch return;
            handle_null_page(arguments.start) catch return;
            const destination = @as([*]u8, @ptrFromInt(arguments.start))[0..arguments.data.len];
            for (destination, arguments.data) |*d, s| {
                d.* = s;
            }
            echo_line("", .{});
            read_memory(arguments.start, null, null);
        },
        .Execute => |arguments| {
            const entry_point: *const fn (?*anyopaque) callconv(.C) void = @ptrFromInt(arguments.start);
            run_on_core(entry_point, null);
            while (true) {
                var it = g_state.usb_xhci_controllers.iterator();
                while (it.next_value()) |controller| {
                    if (usb_xhci.poll_controller(controller)) {
                        usb_hid.poll(
                            controller,
                            &g_state.input_state,
                        );
                    }
                }
                while (g_state.input_state.modifier_key_pressed_events.dequeue()) |scancode| {
                    switch (scancode) {
                        .LeftShift, .RightShift => {
                            g_state.are_characters_shifted = true;
                        },
                        else => {},
                    }
                }
                while (g_state.input_state.modifier_key_released_events.dequeue()) |scancode| {
                    switch (scancode) {
                        .LeftShift, .RightShift => {
                            g_state.are_characters_shifted = false;
                        },
                        else => {},
                    }
                }
                while (g_state.input_state.key_pressed_events.dequeue()) |scancode| {
                    if (scancode == .Escape) {
                        exit_running_program();
                        return;
                    }
                }
                while (g_state.input_state.key_released_events.dequeue()) |scancode| {
                    _ = scancode;
                }
                std.atomic.spinLoopHint();
            }

            toolbox.hang();
        },
    }
}
fn print_apic_id_and_core_id() void {
    const core_id = w64.get_core_id();
    const apic_id = @as(*u32, @ptrFromInt(g_state.apic_address + 0x20)).*;
    print_serial(
        "Core id {}, APIC ID {X}: fbase tls: {x} context: {x},",
        .{
            core_id,
            apic_id,
            fbase_tls,
            @as(u64, @intFromPtr(get_processor_context())),
        },
    );
}
fn get_processor_context() *w64.ApplicationProcessorKernelContext {
    return asm volatile (
        \\rdgsbase %[ret]
        : [ret] "=r" (-> *w64.ApplicationProcessorKernelContext),
    );
}
fn exit_running_program() void {
    print_serial("Escape hit", .{});
    for (g_state.application_processor_contexts) |context| {
        if (context.job.get()) |_| {
            print_serial("Sending NMI to {}", .{context.processor_id});
            const interrupt_command_register_low = amd64.InterruptControlRegisterLow{
                .vector = 0,
                .message_type = .NonMaskableInterrupt,
                .destination_mode = .PhysicalAPICID,
                .is_sent = false,
                .assert_interrupt = false,
                .trigger_mode = .EdgeTriggered,
                .destination_shorthand = .Destination,
            };
            const interrupt_command_register_high = amd64.InterruptControlRegisterHigh{
                .destination = @intCast(context.processor_id),
            };
            print_serial("Low command {X}, High command {X}, ", .{
                @as(u32, @bitCast(interrupt_command_register_low)),
                @as(u32, @bitCast(interrupt_command_register_high)),
            });
            amd64.send_interprocessor_interrupt(
                g_state.apic_address,
                interrupt_command_register_low,
                interrupt_command_register_high,
            );
        }
    }
}
fn read_memory(from_address: ?u64, to_address: ?u64, number_of_bytes: ?u64) void {
    const length = number_of_bytes orelse 1;
    const from = from_address orelse g_state.opened_address;
    const to = to_address orelse from + length;
    if (to < from) {
        echo_line("End address '{X}' must be less start address '{X}'", .{ to, from });
        return;
    }
    handle_null_page(from) catch return;
    g_state.opened_address = to;

    const size = @min(to - from, 256);
    const start = to - size;

    const to_read = @as([*]u8, @ptrFromInt(start))[0..size];
    var cursor: usize = 0;
    const MAX_BYTES_PER_LINE = 16;
    while (cursor < to_read.len) {
        echo_fmt("{X}: ", .{start + cursor});
        const limit = @min(MAX_BYTES_PER_LINE, to_read.len - cursor);
        for (to_read[cursor .. cursor + limit]) |b| {
            echo_fmt("{X} ", .{b});
        }
        echo_line("", .{});

        cursor += limit;
    }
}
fn handle_address_wrap_around(start_address: u64, len: usize) !void {
    var x: u128 = start_address;
    x += len;
    if (x > 0xFFFF_FFFF_FFFF_FFFF) {
        echo_line("Address range wraps around, which is unsupported.", .{});
        return error.AddressWrapsAround;
    }
}
fn handle_null_page(address: u64) !void {
    if (toolbox.align_down(address, w64.MEMORY_PAGE_SIZE) == 0) {
        echo_line("Address range '{X}' is in null page.", .{
            address,
        });
        return error.InNullPage;
    }
}

fn handle_parse_result(parse_result: commands.ParseResult, command_buffer: []const u8) void {
    switch (parse_result) {
        .Command => |command| {
            handle_command(command);
        },
        .HexNumberTooBig => |descriptor| {
            const hex_number_string = command_buffer[descriptor.start..descriptor.end];
            echo_line(
                "Number starting at column {} ('{s}') is too big. Max 8 bytes in length.",
                .{ descriptor.start, hex_number_string },
            );
        },
        .InvalidToken => |bad_token| {
            echo_line("Invalid token '{c}'.", .{bad_token});
        },
        .UnexpectedToken => |token| {
            const token_string = command_buffer[token.start..token.end];
            echo_line("Unexpected token '{s}' at column {}", .{ token_string, token.start });
        },
    }
    echo_line("\n\\", .{});
}

//good for finding where in the code an issue is happening
fn debug_clear_screen_and_hang(r: u8, g: u8, b: u8) void {
    for (g_state.screen.frame_buffer) |*p| {
        p.colors = .{ .r = r, .b = b, .g = g, .reserved = 0 };
    }

    toolbox.hang();
}

//Wozmon64 public API
pub fn run_on_core(entry_point: *const fn (user_data: ?*anyopaque) callconv(.C) void, user_data: ?*anyopaque) void {
    for (g_state.application_processor_contexts) |context| {
        if (context.job.get() == null) {
            context.job.set(.{ .entry = entry_point, .user_data = user_data });
            break;
        }
    }
    //TODO: return error if all cores busy
}

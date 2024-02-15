//Copyright Daniel Bokser 2023
//See LICENSE file for permissible source code usage
pub const w64 = @import("wozmon64_kernel.zig");

const std = @import("std");
const toolbox = @import("toolbox");
const profiler = toolbox.profiler;
const kernel_memory = @import("kernel_memory.zig");
const amd64 = @import("amd64.zig");
const pcie = @import("drivers/pcie.zig");
const usb_xhci = @import("drivers/usb_xhci.zig");
const usb_hid = @import("drivers/usb_hid.zig");
const eth_intel = @import("drivers/ethernet_intel_82574L.zig");
const commands = @import("commands.zig");
const programs = @import("programs.zig");
const boot_log = @import("bootloader_console.zig");
const error_log = @import("error_log.zig");

pub const THIS_PLATFORM = toolbox.Platform.Wozmon64;
pub const ENABLE_PROFILER = true;

const CURSOR_BLINK_TIME_MS = 500;
const ENABLE_SERIAL = toolbox.IS_DEBUG;

pub const InterruptHandler = *const fn (vector_number: u64, error_code: u64) callconv(.C) void;

const KernelState = struct {
    screen: w64.Screen,
    root_xsdt: *const amd64.XSDT,
    application_processor_contexts: []*w64.ApplicationProcessorKernelContext,

    usb_xhci_controllers: toolbox.RandomRemovalLinkedList(*usb_xhci.Controller),
    key_events: w64.KeyEvents,
    are_characters_shifted: bool,
    is_ctrl_down: bool,
    debug_symbols: ?std.dwarf.DwarfInfo,

    global_arena: *toolbox.Arena,
    frame_arena: *toolbox.Arena,
    scratch_arena: *toolbox.Arena,

    interrupt_handler_table: [amd64.IDT_LEN]?InterruptHandler,

    //monitor state
    cursor_x: usize,
    cursor_y: usize,
    last_cursor_update: toolbox.Duration,
    cursor_char: toolbox.Rune,
    is_monitor_enabled: bool,
    rune_buffer: []toolbox.Rune,
    command_buffer: toolbox.DynamicArray(u8),
    opened_address: u64,

    //runtime "constants"
    screen_pixel_width: *u64,
    screen_pixel_height: *u64,
    frame_buffer_size: *u64,
    frame_buffer_stride: *u64,

    //user program state
    user_key_events: ?*w64.KeyEvents,
    is_user_program_running: bool,
    user_working_set: toolbox.DynamicArray(u64),

    //profiler state
    profiler_to_draw: enum {
        BootProfiler,
        FrameProfiler,
    },
    show_profiler: bool,
    last_frames_profiler_snapshot: profiler.State,
    boot_profiler_snapshot: profiler.State,
};

pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    asm volatile ("cli");
    //not set
    _ = ret_addr;
    _ = error_return_trace;

    const global_allocator = g_state.global_arena.zstd_allocator;
    if (g_state.debug_symbols) |*debug_symbols| {
        echo_line("{s}", .{msg});
        var it = w64.StackUnwinder.init();
        while (it.next()) |address| {
            const compile_unit = debug_symbols.findCompileUnit(address) catch |e| {
                echo_line("At {X} CompileUnit error: {}", .{ address, e });
                continue;
            };
            const line_info = debug_symbols.getLineNumberInfo(
                global_allocator,
                compile_unit.*,
                address,
            ) catch |e| {
                echo_line("At {X} Line Info Error: {}", .{ address, e });
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
        if (error_log.get_log().len > 0) {
            echo_line("\nCaused by:\n", .{});
            var error_it = error_log.get_log().iterator();
            while (error_it.next()) |entry| {
                echo_line("{}\n", .{entry.message});
                for (entry.stacktrace.items()) |address| {
                    const compile_unit = debug_symbols.findCompileUnit(address) catch |e| {
                        echo_line("At {X} CompileUnit error: {}", .{ address, e });
                        continue;
                    };
                    const line_info = debug_symbols.getLineNumberInfo(
                        global_allocator,
                        compile_unit.*,
                        address,
                    ) catch |e| {
                        echo_line("At {X} Line Info Error: {}", .{ address, e });
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
                echo_line("", .{});
            }
        }

        if (g_state.is_monitor_enabled) {
            render();
        }
        toolbox.hang();
    } else {
        echo_line("{s}", .{msg});
        var it = w64.StackUnwinder.init();
        while (it.next()) |address| {
            echo_line("At {X}", .{address});
        }
        toolbox.hang();
    }
}

var g_state: KernelState = undefined;

extern var _bss_start: u8;
extern var _bss_end: u8;

export fn kernel_entry(kernel_start_context: *w64.KernelStartContext) callconv(.C) noreturn {
    //disable interrupts
    asm volatile ("cli");

    @setAlignStack(256);
    //clear bss
    {
        const bss_start_address = @intFromPtr(&_bss_start);
        const bss_end_address = @intFromPtr(&_bss_end);
        const len = bss_end_address - bss_start_address;
        const bss = @as([*]u8, @ptrCast(&_bss_start))[0..len];
        @memset(bss, 0);
    }
    profiler.restore(kernel_start_context.boot_profiler_snapshot);

    toolbox.amd64_ticks_to_microseconds = @intCast(kernel_start_context.tsc_mhz);
    {
        const vtable: *std.mem.Allocator.VTable =
            @ptrFromInt(@intFromPtr(kernel_start_context.global_arena.zstd_allocator.vtable));
        vtable.* = toolbox.Arena.ZSTD_VTABLE;
    }
    {
        profiler.begin("Set up boot log");
        defer profiler.end();
        // set up boot log

        @memset(kernel_start_context.screen.back_buffer, .{ .data = 0 });
        boot_log.init_graphics_console(kernel_start_context.screen);
        echo_line("Booting Wozmon64 kernel...", .{});
    }
    {
        const frame_arena =
            kernel_start_context.global_arena.create_arena_from_arena(w64.KERNEL_FRAME_ARENA_SIZE);
        const scratch_arena =
            kernel_start_context.global_arena.create_arena_from_arena(w64.KERNEL_SCRATCH_ARENA_SIZE);
        toolbox.amd64_ticks_to_microseconds = @intCast(kernel_start_context.tsc_mhz);

        g_state = .{
            .is_monitor_enabled = false,
            .cursor_x = 0,
            .cursor_y = 0,
            .last_cursor_update = toolbox.now(),
            .cursor_char = '@',

            .screen = kernel_start_context.screen,
            .root_xsdt = kernel_start_context.root_xsdt,
            .application_processor_contexts = undefined,

            .key_events = w64.KeyEvents.init(kernel_start_context.global_arena),
            .usb_xhci_controllers = toolbox.RandomRemovalLinkedList(*usb_xhci.Controller).init(kernel_start_context.global_arena),
            .are_characters_shifted = false,
            .is_ctrl_down = false,
            .debug_symbols = null,

            .show_profiler = false,
            .profiler_to_draw = .FrameProfiler,
            .last_frames_profiler_snapshot = .{},
            .boot_profiler_snapshot = .{},

            .command_buffer = toolbox.DynamicArray(u8).init(
                kernel_start_context.global_arena,
                kernel_start_context.screen.width_in_runes * kernel_start_context.screen.height_in_runes,
            ),
            .opened_address = 0,
            .rune_buffer = kernel_start_context.global_arena.push_slice_clear(
                toolbox.Rune,
                kernel_start_context.screen.height_in_runes * kernel_start_context.screen.width,
            ),

            .interrupt_handler_table = [_]?InterruptHandler{null} ** amd64.IDT_LEN,

            .global_arena = kernel_start_context.global_arena,
            .frame_arena = frame_arena,
            .scratch_arena = scratch_arena,

            .screen_pixel_height = @ptrFromInt(w64.SCREEN_PIXEL_HEIGHT_ADDRESS),
            .screen_pixel_width = @ptrFromInt(w64.SCREEN_PIXEL_WIDTH_ADDRESS),
            .frame_buffer_size = @ptrFromInt(w64.FRAME_BUFFER_SIZE_ADDRESS),
            .frame_buffer_stride = @ptrFromInt(w64.FRAME_BUFFER_STRIDE_ADDRESS),

            .user_key_events = null,
            .is_user_program_running = false,
            .user_working_set = toolbox.DynamicArray(u64).init(
                kernel_start_context.global_arena,
                32,
            ),
        };
    }

    {
        set_up_gdt(g_state.global_arena);
    }

    {
        set_up_idt(g_state.global_arena);
    }

    {
        profiler.begin("Set up debug symbols");
        defer profiler.end();

        const debug_symbols = parse_dwarf_debug_symbols(
            kernel_start_context.kernel_elf_bytes,
            kernel_start_context.global_arena,
        ) catch |e| {
            echo_line("failed to parse debug symbols: {}", .{e});
            toolbox.hang();
        };
        g_state.debug_symbols = debug_symbols;
    }
    {
        profiler.begin("Set up kernel memory allocator");
        defer profiler.end();

        kernel_memory.init(
            g_state.global_arena,
            kernel_start_context.free_conventional_memory,
            kernel_start_context.next_free_virtual_address,
        );
    }

    //map APIC and set up main core context
    const apic_base_msr = amd64.rdmsr(amd64.IA32_APIC_BASE_MSR);
    const apic_base_physical_address = apic_base_msr &
        toolbox.mask_for_bit_range(12, 63, u64);
    const apic_base_virtual_address = kernel_memory.generate_new_virtual_address(1, w64.MMIO_PAGE_SIZE);
    if (!kernel_memory.map_mmio(
        apic_base_virtual_address,
        apic_base_physical_address,
    )) {
        toolbox.panic(
            "Failed to map APIC to virtual address space! Virtual: {X}, Physcial: {X}",
            .{
                apic_base_virtual_address,
                apic_base_physical_address,
            },
        );
    }

    const apic = amd64.APIC.init(apic_base_virtual_address);
    //set up main core processor context and thread local storage
    {
        const context = g_state.global_arena.push(w64.ApplicationProcessorKernelContext);
        const thread_local_storage = g_state.global_arena.push_slice_clear_aligned(
            u8,
            w64.MEMORY_PAGE_SIZE,
            w64.MEMORY_PAGE_SIZE,
        );
        context.* = .{
            .processor_id = amd64.rdmsr(amd64.IA32_TSC_AUX_MSR),
            .apic = apic,
            .fsbase = @intFromPtr(thread_local_storage.ptr),
            .gsbase = @intFromPtr(context),

            //the following fields are not currently used by the main processor
            .stack_bottom_address = kernel_start_context.stack_bottom_address,
            .cr3 = asm volatile ("mov %%cr3, %[cr3]"
                : [cr3] "=r" (-> u64),
            ),
        };
        asm volatile (
            \\wrfsbase %[fsbase]
            \\wrgsbase %[gsbase]
            :
            : [fsbase] "r" (context.fsbase),
              [gsbase] "r" (context.gsbase),
            : "rax"
        );
    }

    //bring processors in to kernel space
    {
        g_state.application_processor_contexts = g_state.global_arena.push_slice(
            *w64.ApplicationProcessorKernelContext,
            kernel_start_context.bootloader_processor_contexts.len,
        );

        for (kernel_start_context.bootloader_processor_contexts, 0..) |context, i| {
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
            //TODO: should this be page aligned?
            const ap_kernel_context = g_state.global_arena.push_clear(
                w64.ApplicationProcessorKernelContext,
            );
            const rsp = @intFromPtr(stack.ptr) + stack.len;
            const cr3: u64 =
                asm volatile ("mov %%cr3, %[cr3]"
                : [cr3] "=r" (-> u64),
            );
            ap_kernel_context.* = .{
                .cr3 = cr3,
                .stack_bottom_address = rsp,
                //All cores _should_ have the same physical address for their LAPIC.
                //Since they all share the same CR3, they should have the same virtual address
                //(I am hoping this doesn't bite me later...)
                .apic = apic,
                .fsbase = @intFromPtr(thread_local_storage.ptr),
                .gsbase = @intFromPtr(ap_kernel_context),
                .processor_id = context.processor_id,
                .job = .{ .value = null },
            };
            g_state.application_processor_contexts[i] = ap_kernel_context;
        }
        for (g_state.application_processor_contexts, 0..) |context, i| {
            kernel_start_context.bootloader_processor_contexts[i].application_processor_kernel_entry_data.set(.{
                .start_context_data = context,
                .entry = core_entry,
                .cr3 = context.cr3,
                .stack_bottom_address = context.stack_bottom_address,
            });
        }
    }

    //set up drivers
    {
        profiler.begin("set up drivers");
        defer profiler.end();

        const pcie_devices = pcie.enumerate_devices(
            kernel_start_context.root_xsdt,
            g_state.global_arena,
        );
        for (pcie_devices) |dev| {
            switch (dev.header_type) {
                .EndPointDevice => {
                    const end_point_device_header = dev.end_point_device_header();
                    if (end_point_device_header.class_code == pcie.MASS_STORAGE_CLASS_CODE and
                        end_point_device_header.subclass_code == pcie.NVME_SUBCLASS_CODE)
                    {
                        echo_line("Found NVMe drive! ", .{});

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
                                var usb_controller = usb_xhci.init(
                                    dev,
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
                            },
                            pcie.USB_DEVICE_PROGRAMING_INTERFACE => {
                                echo_line("PCIe-attached USB device", .{});
                            },
                            else => {
                                echo_line("USB controller: {}", .{end_point_device_header});
                            },
                        }
                    } else if (end_point_device_header.class_code == pcie.NETWORK_CONTROLLER_CLASS_CODE and
                        end_point_device_header.subclass_code == pcie.ETHERNET_CONTROLLER_SUBCLASS_CODE)
                    {
                        if (end_point_device_header.vendor_id == eth_intel.VENDOR_ID and end_point_device_header.device_id == eth_intel.DEVICE_ID) {
                            //TODO
                            _ = eth_intel.init(dev);
                        }
                    } else {
                        echo_line("Unsupported PCIe device.  Class: {X}, SubClass: {X}", .{
                            end_point_device_header.class_code,
                            end_point_device_header.subclass_code,
                        });
                    }
                },
                .BridgeDevice => {
                    //TODO
                },
            }
        }

        echo_line("PCIE devices len: {}", .{pcie_devices.len});
    }

    //populate runtime constants
    {
        g_state.screen_pixel_width.* = g_state.screen.width;
        g_state.screen_pixel_height.* = g_state.screen.height;
        g_state.frame_buffer_size.* = g_state.screen.frame_buffer.len;
        g_state.frame_buffer_stride.* = g_state.screen.stride;
    }

    //enable monitor
    {
        g_state.is_monitor_enabled = true;
        boot_log.disable();
    }

    {
        echo_welcome_line("*** Wozmon64 ***\n", .{});
        echo_welcome_line("{} bytes free *** {} processors free *** {} x {} pixels free\n", .{
            kernel_memory.pages_free() * w64.MEMORY_PAGE_SIZE,
            g_state.application_processor_contexts.len,
            g_state.screen.width,
            g_state.screen.height,
        });
    }

    echo_line("\\", .{});

    //enable interrupts
    asm volatile ("sti");

    profiler.end_profiler();
    g_state.boot_profiler_snapshot = profiler.save();
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
        \\mov %%cr3, %%rax
        \\mov %%rax, %%cr3 #flush TLB
        \\
        \\wrfsbase %[fsbase]
        \\wrgsbase %[gsbase]
        :
        : [fsbase] "r" (context.fsbase),
          [gsbase] "r" (context.gsbase),
        : "rax"
    );
    //println_serial("APIC register {X}", .{amd64.rdmsr(amd64.IA32_APIC_BASE_MSR)});
    fbase_tls = context.fsbase;
    //print_apic_id_and_core_id();

    while (true) {
        if (context.job.get()) |job| {
            job.entry(job.user_data);
            context.job.set(null);
        }
        std.atomic.spinLoopHint();
    }
}
pub inline fn allocate_memory(n: usize) []align(w64.MEMORY_PAGE_SIZE) u8 {
    return kernel_memory.allocate_conventional(
        @divTrunc(toolbox.align_up(n, w64.MEMORY_PAGE_SIZE), w64.MEMORY_PAGE_SIZE),
    )[0..n];
}

pub inline fn free_memory(data: []u8) void {
    const vaddr = @intFromPtr(data.ptr);
    const vaddr_aligned = toolbox.align_down(vaddr, w64.MEMORY_PAGE_SIZE);
    const new_len = data.len + (vaddr - vaddr_aligned);

    const aligned_data =
        @as(
        [*]align(w64.MEMORY_PAGE_SIZE) u8,
        @ptrFromInt(vaddr_aligned),
    )[0..new_len];
    kernel_memory.free_conventional(aligned_data);
}

fn parse_dwarf_debug_symbols(kernel_elf: []const u8, arena: *toolbox.Arena) !std.dwarf.DwarfInfo {
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
    {
        profiler.begin("Parse DWARF");
        defer profiler.end();

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
}

pub fn echo_welcome_line(comptime fmt: []const u8, args: anytype) void {
    const scratch_arena = g_state.scratch_arena;
    scratch_arena.save();
    defer scratch_arena.restore();

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
    if (!g_state.is_monitor_enabled) {
        boot_log.print(fmt, args);
        return;
    }

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

pub fn register_interrupt_handler(interrupt_handler: InterruptHandler, vector: usize) void {
    g_state.interrupt_handler_table[vector] = interrupt_handler;
}
pub fn register_exception_handler(exception_handler: InterruptHandler, exception_code: amd64.ExceptionCode) void {
    g_state.interrupt_handler_table[@intFromEnum(exception_code)] = exception_handler;
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
    const idt = arena.push_slice_clear(amd64.IDTDescriptor, amd64.IDT_LEN);
    const idt_register = amd64.IDTRegister{
        .limit = @intCast(idt.len * @sizeOf(amd64.IDTDescriptor) - 1),
        .idt = idt.ptr,
    };

    inline for (0..amd64.IDT_LEN) |i| {
        const handler = make_interrupt_handler(i);
        const handler_addr = @intFromPtr(handler);
        idt[i] =
            .{
            .offset_bits_0_to_15 = @as(u16, @truncate(handler_addr)),
            .selector = asm volatile ("mov %%cs, %[ret]"
                : [ret] "=r" (-> u16),
                :
                : "cs"
            ),
            .ist = 0,
            .type_attr = .InterruptGate64Bit,
            .zeroA = 0,
            .privilege_bits = 0,
            .is_present = true,
            .offset_bits_16_to_31 = @as(u16, @truncate(handler_addr >> 16)),
            .offset_bits_32_to_63 = @as(u32, @truncate(handler_addr >> 32)),
            .zeroB = 0,
        };
    }
    register_exception_handler(&page_fault_handler, .PageFault);
    register_exception_handler(&invalid_opcode_handler, .InvalidOpcode);
    register_exception_handler(&nmi_handler, .NMI);
    register_exception_handler(&double_fault_handler, .DoubleFault);
    register_exception_handler(&general_protection_fault_handler, .GeneralProtectionFault);

    asm volatile (
        \\lidt (%[idtr])
        :
        : [idtr] "r" (&idt_register),
    );
}
fn double_fault_handler(vector_number: u64, error_code: u64) callconv(.C) void {
    _ = vector_number;
    toolbox.panic("Double fault occurred! Error code: {}", .{error_code});
}
fn general_protection_fault_handler(vector_number: u64, error_code: u64) callconv(.C) void {
    _ = vector_number; // autofix
    toolbox.panic("General protection fault occurred! Error code: {}", .{error_code});
}
fn nmi_handler(vector_number: u64, error_code: u64) callconv(.C) void {
    _ = error_code;
    _ = vector_number;
    const processor_context = w64.get_processor_context();

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
          [stack_virtual_address] "r" (processor_context.stack_bottom_address - 8),
          [ksc_addr] "r" (@intFromPtr(processor_context)),
          [entry_point] "r" (@intFromPtr(&core_entry)),
        : "rdi"
    );
}
fn page_fault_handler(vector_number: u64, error_code: u64) callconv(.C) void {
    _ = vector_number;
    _ = error_code;
    const unmapped_address = asm volatile ("mov %%cr2, %[unmapped_address]"
        : [unmapped_address] "=r" (-> u64),
    );
    if (unmapped_address == 0xFFFFFFFFB20060C8) {
        asm volatile ("nop");
    }

    const to_map = toolbox.align_down(unmapped_address, w64.MEMORY_PAGE_SIZE);
    if (to_map == 0) {
        toolbox.panic("Allocating memory at null page! Address: {X}", .{unmapped_address});
    }
    if (!kernel_memory.is_valid_2mb_page_virtual_address(to_map)) {
        toolbox.panic("Page fault at MMIO address: {X}", .{unmapped_address});
    }

    const page = kernel_memory.allocate_conventional_at_address(to_map, 1);
    @memset(page, 0);

    if (!w64.is_kernel_address(to_map) and to_map >= w64.DEFAULT_PROGRAM_LOAD_ADDRESS) {
        g_state.user_working_set.append(to_map);
    }
}

fn invalid_opcode_handler(vector_number: u64, error_code: u64) callconv(.C) void {
    _ = error_code;
    _ = vector_number;
    toolbox.panic("Invalid opcode!", .{});
}
export fn interrupt_handler_common_inner(vector_number: u64, error_code: u64) callconv(.C) void {
    //NOTE: debug code
    // echo_line("Vector number: {}, error code: {}", .{ vector_number, error_code });
    // var it = StackUnwinder.init();
    // while (it.next()) |address| {
    //     echo_line("At {X}", .{address});
    // }
    if (g_state.interrupt_handler_table[vector_number]) |interrupt_handler| {
        interrupt_handler(vector_number, error_code);
    } else {
        toolbox.panic("No interrupt handler for vector number {}.  Error code: {}", .{
            vector_number, error_code,
        });
    }
}

//heavily inspired by https://github.com/FlorenceOS/Florence/blob/aaa5a9e568197ad24780ec9adb421217530d4466/subprojects/flork/src/platform/x86_64/interrupts.zig#L167
fn make_interrupt_handler(comptime vector_number: comptime_int) *const fn () callconv(.Naked) void {
    const has_error_code = switch (comptime vector_number) {
        0x00...0x07 => false,
        0x08 => true,
        0x09 => false,
        0x0A...0x0E => true,
        0x0F...0x10 => false,
        0x11 => true,
        0x12...0x14 => false,
        0x1E => true,
        else => false,
    };
    const push_fake_error_code_instruction = if (has_error_code)
        ""
    else
        "pushq $0\n";
    return &struct {
        fn handler() callconv(.Naked) void {
            asm volatile (push_fake_error_code_instruction ++
                    \\pushq %[vector_number]
                    \\jmp interrupt_handler_common
                :
                : [vector_number] "i" (vector_number),
            );
        }
    }.handler;
}

comptime {
    const SAVE_FRAME_POINTER = if (toolbox.IS_DEBUG)
        \\
        \\lea 16(%rsp), %rbp
        \\
    else
        \\
        \\
        ;

    asm (
        \\.global interrupt_handler_common
        \\.extern interrupt_handler_common_inner
        \\interrupt_handler_common:
        \\
        \\xchg %rbp, 8(%rsp) #save previous frame pointer. rbp now has error code 
        \\xchg %rdi, (%rsp) #rdi has the vector number
        \\
        \\push %rsi
        \\mov %rbp, %rsi #rsi now has the error code
        ++ SAVE_FRAME_POINTER ++
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
            \\call interrupt_handler_common_inner
            \\
            \\movdqu 0(%rsp), %xmm0 
            \\movdqu 0x10(%rsp), %xmm1
            \\movdqu 0x20(%rsp), %xmm2
            \\movdqu 0x30(%rsp), %xmm3
            \\movdqu 0x40(%rsp), %xmm4
            \\movdqu 0x50(%rsp), %xmm5
            \\movdqu 0x60(%rsp), %xmm6 
            \\movdqu 0x70(%rsp), %xmm7 
            \\movdqu 0x80(%rsp), %xmm8 
            \\movdqu 0x90(%rsp), %xmm9 
            \\movdqu 0xA0(%rsp), %xmm10 
            \\movdqu 0xB0(%rsp), %xmm11
            \\movdqu 0xC0(%rsp), %xmm12
            \\movdqu 0xD0(%rsp), %xmm13
            \\movdqu 0xE0(%rsp), %xmm14
            \\movdqu 0xF0(%rsp), %xmm15
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
            \\pop %rdi
            \\pop %rbp
            \\iretq
    );
}

fn main_loop() void {
    while (true) {
        profiler.start_profiler();
        profiler.begin("Frame");
        while (g_state.key_events.modifier_key_pressed_events.dequeue()) |scancode| {
            switch (scancode) {
                .LeftShift, .RightShift => {
                    g_state.are_characters_shifted = true;
                },
                .LeftCtrl, .RightCtrl => {
                    g_state.is_ctrl_down = true;
                },
                else => {},
            }
        }
        while (g_state.key_events.modifier_key_released_events.dequeue()) |scancode| {
            switch (scancode) {
                .LeftShift, .RightShift => {
                    g_state.are_characters_shifted = false;
                },
                .LeftCtrl, .RightCtrl => {
                    g_state.is_ctrl_down = false;
                },
                else => {},
            }
        }
        profiler.begin("Key pressed events");
        while (g_state.key_events.key_pressed_events.dequeue()) |scancode| {
            switch (scancode) {
                .F1 => type_program(programs.woz_and_jobs),
                .F2 => type_program(programs.doom),
                .F3 => {
                    if (g_state.show_profiler and g_state.profiler_to_draw == .FrameProfiler) {
                        g_state.show_profiler = false;
                    } else {
                        g_state.show_profiler = true;
                        g_state.profiler_to_draw = .FrameProfiler;
                    }
                },
                .F4 => {
                    if (g_state.show_profiler and g_state.profiler_to_draw == .BootProfiler) {
                        g_state.show_profiler = false;
                    } else {
                        g_state.show_profiler = true;
                        g_state.profiler_to_draw = .BootProfiler;
                    }
                },
                else => type_key(scancode, g_state.are_characters_shifted),
            }
        }
        profiler.end();

        profiler.begin("Key released events");
        while (g_state.key_events.key_released_events.dequeue()) |scancode| {
            _ = scancode;
        }
        profiler.end();

        blink_cursor();

        render();

        profiler.end();
        profiler.end_profiler();
        g_state.last_frames_profiler_snapshot = profiler.save();
    }
}
fn render() void {
    {
        profiler.begin("Clear back buffer");
        @memset(g_state.screen.back_buffer, .{ .data = 0 });
        profiler.end();
    }

    {
        if ((comptime ENABLE_PROFILER) and g_state.show_profiler) {
            profiler.begin("Draw Profiler");
            draw_profiler();
            profiler.end();
        } else {
            draw_runes();
            draw_cursor();
        }
    }

    {
        profiler.begin("Blit to screen");
        @memcpy(g_state.screen.frame_buffer, g_state.screen.back_buffer);
        profiler.end();
    }
}

fn draw_profiler() void {
    if (comptime !ENABLE_PROFILER) {
        return;
    }

    g_state.scratch_arena.save();
    defer g_state.scratch_arena.restore();
    const profiler_snapshot = switch (g_state.profiler_to_draw) {
        .FrameProfiler => g_state.last_frames_profiler_snapshot,
        .BootProfiler => g_state.boot_profiler_snapshot,
    };

    var stats = profiler.compute_statistics(profiler_snapshot, g_state.scratch_arena);
    draw_line(
        toolbox.str8fmt(
            "Total elapsed: {}ms",
            .{stats.total_elapsed.milliseconds()},
            g_state.scratch_arena,
        ),
        0,
    );
    stats.section_statistics.sort_reverse("percent_with_children");

    for (stats.section_statistics.items(), 0..) |section_stats, line_number| {
        const offset_y = 1;
        draw_line(section_stats.str8(g_state.scratch_arena), line_number + offset_y);
    }
}

fn draw_line(line: toolbox.String8, line_y: usize) void {
    var rune_x: usize = 0;
    var it = line.iterator();
    while (it.next()) |rune_and_length| {
        draw_rune(rune_and_length.rune, rune_x, line_y, 10);
        rune_x += 1;
    }
}

fn draw_runes() void {
    var rune_x: usize = 0;
    var rune_y: usize = 0;
    const rune_buffer = g_state.rune_buffer;
    for (rune_buffer) |c| {
        draw_rune(c, rune_x, rune_y, 0);

        rune_x += 1;
        if (rune_x >= g_state.screen.width_in_runes) {
            rune_x = 0;
            rune_y += 1;
        }
    }
}
fn draw_rune(rune: toolbox.Rune, rune_x: usize, rune_y: usize, vertical_padding: usize) void {
    const r = switch (rune) {
        'a'...'z' => rune - 32,
        else => rune,
    };
    if (r < ' ' or r > '_') {
        return;
    }
    const ascii: u8 = @intCast(r);
    const index = ascii - ' ';
    const font = g_state.screen.font;
    const bitmap = font.character_bitmap(index);

    draw_bitmap(
        bitmap,
        0,
        0,
        rune_x * font.kerning,
        rune_y * (font.height + vertical_padding),
        font.width,
        font.height,
    );
}

//TODO: support signed coordinates
fn draw_bitmap(
    bitmap: []w64.Pixel,
    sx: usize,
    sy: usize,
    dx: usize,
    dy: usize,
    width: usize,
    height: usize,
) void {
    var src_cursor_y: usize = sy;
    var dest_cursor_y: usize = dy;
    const src_end_y = sy + height;
    const dest_end_y = dy + height;

    while (src_cursor_y < src_end_y and dest_cursor_y < dest_end_y) : ({
        src_cursor_y += 1;
        dest_cursor_y += 1;
    }) {
        var src_cursor_x: usize = sx;
        var dest_cursor_x: usize = dx;
        const src_end_x = sx + width;
        const dest_end_x = dx + width;
        while (src_cursor_x < src_end_x and dest_cursor_x < dest_end_x) : ({
            src_cursor_x += 1;
            dest_cursor_x += 1;
        }) {
            const src_index = src_cursor_y * width + src_cursor_x;
            const dest_index = dest_cursor_y * g_state.screen.stride + dest_cursor_x;
            g_state.screen.back_buffer[dest_index] = bitmap[src_index];
        }
    }
}

fn blink_cursor() void {
    profiler.begin("blink cursor");
    defer profiler.end();
    const now = toolbox.now();
    if (now.subtract(g_state.last_cursor_update).milliseconds() >= CURSOR_BLINK_TIME_MS) {
        g_state.last_cursor_update = now;
        g_state.cursor_char = if (g_state.cursor_char == '@') ' ' else '@';
    }
}

fn draw_cursor() void {
    draw_rune(g_state.cursor_char, g_state.cursor_x, g_state.cursor_y, 0);
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
    const load_address: u32 = w64.DEFAULT_PROGRAM_LOAD_ADDRESS;
    const dest = @as([*]u8, @ptrFromInt(load_address))[0..program.len];
    @memset(dest, 0);
    @memcpy(dest, program);

    g_state.command_buffer.clear();
    echo_line("\nLoaded {} byte program to address {X}!", .{ program.len, load_address });
    type_number(load_address);
    type_key(.Slash, false);
    type_number(@as(u32, 16));
    type_key(.Enter, false);
    type_number(load_address);
    type_key(.R, false);

    // type_number(@as(u32, w64.DEFAULT_PROGRAM_LOAD_ADDRESS));
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
            var system_api = w64.ProgramContext{
                .tsc_mhz = toolbox.amd64_ticks_to_microseconds,
                .error_and_terminate = &user_program_error_and_terminate,
                .terminate = &user_program_terminate,
                .register_key_events_queue = &register_key_events_queue,
            };
            g_state.is_user_program_running = true;
            run_on_core(entry_point, &system_api);
            while (true) {
                if (!@atomicLoad(bool, &g_state.is_user_program_running, .SeqCst)) {
                    exit_running_program();
                    return;
                }
                // var it = g_state.usb_xhci_controllers.iterator();
                // while (it.next_value()) |controller| {
                //     if (usb_xhci.poll_controller(controller)) {
                //         usb_hid.poll(
                //             controller,
                //             &g_state.key_events,
                //         );
                //     }
                // }
                while (g_state.key_events.modifier_key_pressed_events.dequeue()) |scancode| {
                    switch (scancode) {
                        .LeftShift, .RightShift => {
                            g_state.are_characters_shifted = true;
                        },
                        .LeftCtrl, .RightCtrl => {
                            g_state.is_ctrl_down = true;
                        },
                        else => {},
                    }
                    if (g_state.user_key_events) |user_key_events| {
                        user_key_events.modifier_key_pressed_events.force_enqueue(scancode);
                    }
                }
                while (g_state.key_events.modifier_key_released_events.dequeue()) |scancode| {
                    switch (scancode) {
                        .LeftShift, .RightShift => {
                            g_state.are_characters_shifted = false;
                        },
                        .LeftCtrl, .RightCtrl => {
                            g_state.is_ctrl_down = false;
                        },
                        else => {},
                    }
                    if (g_state.user_key_events) |user_key_events| {
                        user_key_events.modifier_key_released_events.force_enqueue(scancode);
                    }
                }
                while (g_state.key_events.key_pressed_events.dequeue()) |scancode| {
                    if (scancode == .Escape and g_state.is_ctrl_down) {
                        exit_running_program();
                        return;
                    }
                    if (g_state.user_key_events) |user_key_events| {
                        user_key_events.key_pressed_events.force_enqueue(scancode);
                    }
                }
                while (g_state.key_events.key_released_events.dequeue()) |scancode| {
                    if (g_state.user_key_events) |user_key_events| {
                        user_key_events.key_released_events.force_enqueue(scancode);
                    }
                }
                std.atomic.spinLoopHint();
            }

            toolbox.hang();
        },
    }
}
fn print_apic_id_and_core_id() void {
    const core_id = w64.get_core_id();
    const apic = w64.get_processor_context().apic;
    const apic_id = apic.read_register(amd64.APICIDRegister).apic_id;
    echo_line(
        "Core id {}, APIC ID {X}: fbase tls: {x} context: {x},",
        .{
            core_id,
            apic_id,
            fbase_tls,
            @as(u64, @intFromPtr(w64.get_processor_context())),
        },
    );
}
fn exit_running_program() void {
    for (g_state.application_processor_contexts) |context| {
        if (context.job.get()) |_| {
            const interrupt_command_register_low = amd64.APICInterruptControlRegisterLow{
                .vector = 0,
                .message_type = .NonMaskableInterrupt,
                .destination_mode = .PhysicalAPICID,
                .is_sent = false,
                .assert_interrupt = false,
                .trigger_mode = .EdgeTriggered,
                .destination_shorthand = .Destination,
            };
            const interrupt_command_register_high = amd64.APICInterruptControlRegisterHigh{
                .destination = @intCast(context.processor_id),
            };
            amd64.send_interprocessor_interrupt(
                w64.get_processor_context().apic,
                interrupt_command_register_low,
                interrupt_command_register_high,
            );
        }
    }

    g_state.user_key_events = null;
    for (g_state.user_working_set.items()) |page_virtual_address| {
        const mapped_physical_address = kernel_memory.unmap(page_virtual_address);
        toolbox.assert(mapped_physical_address != 0, "Unmapping bad virtual address: {X}", .{page_virtual_address});
    }
    g_state.user_working_set.clear();
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

pub fn xhci_interrupt_handler(_: u64, _: u64) callconv(.C) void {
    // debug_clear_screen_and_hang(123, 12, 23);
    const apic = w64.get_processor_context().apic;
    const vector = amd64.get_in_service_interrupt_vector(apic);
    toolbox.assert(vector != 0, "Interrupt handler called with no interrupt in service", .{});

    var it = g_state.usb_xhci_controllers.iterator();
    while (it.next()) |controller_ptr| {
        const controller = controller_ptr.*;
        if (controller.interrupt_vector != vector) {
            continue;
        }

        const should_poll_hid = usb_xhci.poll_controller(controller);

        if (should_poll_hid) {
            usb_hid.poll(
                controller,
                &g_state.key_events,
            );
        }
        usb_xhci.send_end_of_interrupt(controller);
    }
    amd64.send_end_of_interrupt(apic);
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

pub fn register_key_events_queue(key_events: *w64.KeyEvents) callconv(.C) void {
    //TODO atomic store
    g_state.user_key_events = key_events;
}

pub fn user_program_terminate() callconv(.C) noreturn {
    @atomicStore(bool, &g_state.is_user_program_running, false, .SeqCst);
    toolbox.hang();
}

pub fn user_program_error_and_terminate(bytes: [*c]const u8, len: u64) callconv(.C) noreturn {
    echo_line("Program terminated with error: {s}", .{bytes[0..len]});
    user_program_terminate();
}

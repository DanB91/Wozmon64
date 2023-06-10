//Copyright Daniel Bokser 2023
//See LICENSE file for permissible source code usage

const std = @import("std");
const toolbox = @import("toolbox");
const mpsp = @import("mp_service_protocol.zig");
const w64 = @import("wozmon64_definitions.zig");
const console = @import("bootloader_console.zig");

const KERNEL_ELF = @embedFile("../zig-out/bin/kernel.elf");
const MEMORY_PAGE_SIZE = toolbox.mb(2);
const MMIO_PAGE_SIZE = toolbox.kb(4);
const UEFI_PAGE_SIZE = toolbox.kb(4);

const ENABLE_CONSOLE = true;

const ZSGraphicsOutputProtocol = std.os.uefi.protocols.GraphicsOutputProtocol;
const ZSGraphicsOutputModeInformation = std.os.uefi.protocols.GraphicsOutputModeInformation;
const ZSUEFIStatus = std.os.uefi.Status;
const ZSMemoryDescriptor = std.os.uefi.tables.MemoryDescriptor;

const SmallUEFIMemoryDescriptor = ZSMemoryDescriptor;

const println = console.println;

comptime {
    toolbox.static_assert(
        @sizeOf(w64.Pixel) == 4,
        "Pixel size incorrect",
    );
}

pub const LargeUEFIMemoryDescriptor = extern struct {
    type: std.os.uefi.tables.MemoryType,
    physical_start: u64,
    virtual_start: u64,
    number_of_pages: u64,
    attribute: std.os.uefi.tables.MemoryDescriptorAttribute,
    unknown: u64,
};

pub const ConventionalMemoryDescriptor = struct {
    physical_address: u64,
    number_of_pages: usize,

    const PAGE_SIZE = MEMORY_PAGE_SIZE;
};
pub const MMIOMemoryDescriptor = struct {
    physical_address: u64,
    virtual_address: u64,
    number_of_pages: usize,

    const PAGE_SIZE = MMIO_PAGE_SIZE;
};

const KernelParseResult = struct {
    next_free_virtual_address: u64,
    entry_point: u64,
    top_of_stack_address: u64,
    page_table_data: toolbox.RandomRemovalLinkedList(PageTableData),
};
const PageTableData = struct {
    destination_virtual_address: u64,
    data_to_copy: []const u8,
    number_of_bytes: usize,
    is_executable: bool,
    is_writable: bool,
};

pub fn main() noreturn {
    //disable interrupts
    asm volatile ("cli");

    const system_table = std.os.uefi.system_table;
    const handle = std.os.uefi.handle;

    const con_out = system_table.con_out.?;
    _ = con_out.reset(false);
    _ = con_out.clearScreen();
    _ = con_out.setCursorPosition(0, 0);

    const bs = system_table.boot_services.?;

    var bootloader_arena_buffer = [_]u8{0} ** toolbox.kb(512);
    var bootloader_arena = toolbox.Arena.init_with_buffer(&bootloader_arena_buffer);

    //graphics

    var gop: *ZSGraphicsOutputProtocol = undefined;
    var found_valid_resolution = false;
    var screen: w64.Screen = b: {
        var status = bs.locateProtocol(&ZSGraphicsOutputProtocol.guid, null, @ptrCast(*?*anyopaque, &gop));
        if (status != ZSUEFIStatus.Success) {
            fatal("Cannot init graphics system! Error locating GOP protocol: {}", .{status});
        }

        //set graphics mode to 0 if NotStarted is returned
        {
            var gop_mode_info: *ZSGraphicsOutputModeInformation = undefined;
            var size_of_info: usize = 0;
            const query_mode_status = gop.queryMode(0, &size_of_info, &gop_mode_info);
            if (query_mode_status == .NotStarted) {
                _ = gop.setMode(0);
            }
        }
        var mode: u32 = 0;
        for (0..gop.mode.max_mode + 1) |i| {
            mode = @intCast(u32, i);
            var gop_mode_info: *ZSGraphicsOutputModeInformation = undefined;
            var size_of_info: usize = 0;
            const query_mode_status = gop.queryMode(mode, &size_of_info, &gop_mode_info);
            if (query_mode_status == .Success) {
                toolbox.assert(
                    @sizeOf(ZSGraphicsOutputModeInformation) == size_of_info,
                    "Wrong size for GOP mode info. Expected: {}, Actual: {}",
                    .{
                        @sizeOf(ZSGraphicsOutputModeInformation),
                        size_of_info,
                    },
                );
                if (gop_mode_info.horizontal_resolution == w64.TARGET_RESOLUTION.width and
                    gop_mode_info.vertical_resolution == w64.TARGET_RESOLUTION.height)
                {
                    found_valid_resolution = true;
                    status = gop.setMode(mode);
                    if (status != ZSUEFIStatus.Success) {
                        fatal("Cannot init graphics system! Error setting mode {}: {}", .{ mode, status });
                    }
                    break;
                }
            }
        }
        if (!found_valid_resolution) {
            fatal(
                "Failed to set screen to required resolution: {}x{}",
                .{
                    w64.TARGET_RESOLUTION.width,
                    w64.TARGET_RESOLUTION.height,
                },
            );
        }

        const frame_buffer = @intToPtr([*]w64.Pixel, gop.mode.frame_buffer_base)[0 .. gop.mode.frame_buffer_size / @sizeOf(w64.Pixel)];
        break :b .{
            .frame_buffer = frame_buffer,
            .back_buffer = undefined,
            .width = gop.mode.info.horizontal_resolution,
            .height = gop.mode.info.vertical_resolution,
            .stride = gop.mode.info.pixels_per_scan_line,
        };
    };

    //TODO: get rsdp
    var rsdp: u64 = 0;
    {
        const ACPI2RSDP = extern struct {
            signature: [8]u8,
            checksum: u8,
            oem_id: [6]u8,
            revision: u8,
            rsdt_address: u32,
            length: u32,
            xsdt_address_low: u32,
            xsdt_address_high: u32,
            extended_checksum: u8,
            reserved: [3]u8,
        };
        table_loop: for (0..system_table.number_of_table_entries) |i| {
            if (system_table.configuration_table[i].vendor_guid.eql(std.os.uefi.tables.ConfigurationTable.acpi_20_table_guid)) {
                const tmp_rsdp = @ptrCast(*ACPI2RSDP, @alignCast(
                    @alignOf(ACPI2RSDP),
                    system_table.configuration_table[i].vendor_table,
                ));
                if (std.mem.eql(u8, &tmp_rsdp.signature, "RSD PTR ")) {
                    rsdp = @ptrToInt(tmp_rsdp);
                    break :table_loop;
                }
            }
        } else {
            fatal("Cannot find rsdp!", .{});
        }
    }

    //get memory map
    var memory_map: []LargeUEFIMemoryDescriptor = undefined;
    var map_key: usize = 0;
    {
        const MAX_MEMORY_DESCRIPTORS = 512;
        var mmap_store: [MAX_MEMORY_DESCRIPTORS]LargeUEFIMemoryDescriptor = undefined;
        var mmap_size: usize = @sizeOf(@TypeOf(mmap_store));
        var descriptor_size: usize = 0;
        var descriptor_version: u32 = 0;
        var status = bs.getMemoryMap(&mmap_size, @ptrCast([*]SmallUEFIMemoryDescriptor, &mmap_store), &map_key, &descriptor_size, &descriptor_version);
        if (status != ZSUEFIStatus.Success) {
            fatal("Failed to get memory map! Error: {}", .{status});
        }

        if (descriptor_size != @sizeOf(LargeUEFIMemoryDescriptor)) {
            fatal(
                "Unexpected size of memory descriptor. Expected: {}, Actual {}. Version: {}",
                .{
                    @sizeOf(LargeUEFIMemoryDescriptor),
                    descriptor_size,
                    descriptor_version,
                },
            );
        }

        const num_descriptors = mmap_size / descriptor_size;
        memory_map = bootloader_arena.push_slice(LargeUEFIMemoryDescriptor, num_descriptors);
        @memcpy(memory_map, mmap_store[0..num_descriptors]);
    }

    //exit boot services
    {
        const status = bs.exitBootServices(handle, map_key);
        if (status != ZSUEFIStatus.Success) {
            fatal(
                "Failed to exit boot services! Error: {}, Handle: {}, Map key: {X}",
                .{ status, handle, map_key },
            );
        }
        console.exit_boot_services();
    }
    {
        system_table.console_in_handle = null;
        system_table.con_in = null;
        system_table.console_out_handle = null;
        system_table.con_out = null;
        system_table.standard_error_handle = null;
        system_table.std_err = null;
        system_table.boot_services = null;
    }

    //TODO: multicore
    // draw_strip(
    //     0,
    //     cores_detected,
    //     screen,
    // );
    // @atomicStore(bool, &print_strip, true, .SeqCst);

    const kernel_start_context_page = b: {
        for (memory_map) |*desc| {
            switch (desc.type) {
                .ConventionalMemory => {
                    const descriptor_size = desc.number_of_pages * UEFI_PAGE_SIZE;
                    if (descriptor_size >= MEMORY_PAGE_SIZE) {
                        const ret = @intToPtr([*]u8, desc.physical_start)[0..MEMORY_PAGE_SIZE];
                        desc.number_of_pages -= MEMORY_PAGE_SIZE / UEFI_PAGE_SIZE;
                        desc.physical_start += MEMORY_PAGE_SIZE;
                        break :b ret;
                    }
                },
                else => {},
            }
        } else {
            //TODO: proper fatal function
            println("failed to find enough memory for kernel start context", .{});
            toolbox.hang();
        }
    };
    var kernel_start_arena = toolbox.Arena.init_with_buffer(kernel_start_context_page);

    //allocate back buffer
    screen.back_buffer = b: {
        const number_of_pages_to_allocate =
            toolbox.align_up(screen.frame_buffer.len * @sizeOf(w64.Pixel), MEMORY_PAGE_SIZE) /
            UEFI_PAGE_SIZE;
        for (memory_map) |*desc| {
            switch (desc.type) {
                .ConventionalMemory => {
                    if (desc.number_of_pages >= number_of_pages_to_allocate) {
                        const ret = @intToPtr([*]w64.Pixel, desc.physical_start)[0..screen.frame_buffer.len];
                        desc.number_of_pages -= number_of_pages_to_allocate;
                        desc.physical_start += number_of_pages_to_allocate * UEFI_PAGE_SIZE;

                        //clear memory
                        @memset(ret, .{ .data = 0 });
                        break :b ret;
                    }
                },
                else => {},
            }
        } else {
            //TODO: proper fatal function
            println("failed to find enough memory for kernel start context", .{});
            toolbox.hang();
        }
    };
    console.init_graphics_console(screen);
    println("back buffer len: {}, screen len: {}", .{ screen.back_buffer.len, screen.frame_buffer.len });

    const kernel_parse_result = parse_kernel_elf(&kernel_start_arena) catch |e| {
        //TODO: proper fatal function
        println("failed to parse kernel elf: {}", .{e});
        toolbox.hang();
    };
    var next_free_virtual_address = kernel_parse_result.next_free_virtual_address;

    //collect conventional memory and MMIO descriptors
    var conventional_memory_descriptors = toolbox.RandomRemovalLinkedList(ConventionalMemoryDescriptor)
        .init(&kernel_start_arena);
    var mmio_descriptors = toolbox.RandomRemovalLinkedList(MMIOMemoryDescriptor)
        .init(&kernel_start_arena);
    for (memory_map) |desc| {
        const descriptor_size = desc.number_of_pages * UEFI_PAGE_SIZE;
        switch (desc.type) {
            .ConventionalMemory => {
                if (descriptor_size >= MEMORY_PAGE_SIZE) {
                    const number_of_pages = descriptor_size / MEMORY_PAGE_SIZE;
                    _ = conventional_memory_descriptors.append(.{
                        .physical_address = desc.physical_start,
                        .number_of_pages = number_of_pages,
                    });
                }
            },
            .ACPIMemoryNVS, .ACPIReclaimMemory => {
                _ = mmio_descriptors.append(.{
                    .virtual_address = next_free_virtual_address,
                    .physical_address = desc.physical_start,
                    .number_of_pages = desc.number_of_pages,
                });
                next_free_virtual_address += descriptor_size;
            },
            else => {
                //TODO?
            },
        }
    }
    {
        //TODO: set up page tables
        //1) map kernel_start_context_page
        //2) map MMIO addresses
    }

    //dump debug memory data
    {
        println("rsdp: 0x{X}", .{rsdp});
        println("start context page address: 0x{X}", .{@ptrToInt(kernel_start_context_page.ptr)});
        {
            var it = conventional_memory_descriptors.iterator();
            while (it.next()) |desc| {
                println("Conventional Memory:  paddr: {X}, number of pages: {}", .{
                    desc.physical_address,
                    desc.number_of_pages,
                });
            }
        }
        {
            var it = mmio_descriptors.iterator();
            while (it.next()) |desc| {
                println("MMIO: vaddr: {X}, paddr: {X}, number of pages: {}", .{
                    desc.virtual_address,
                    desc.physical_address,
                    desc.number_of_pages,
                });
            }
        }
    }

    toolbox.hang();
}
fn draw_test(screen: w64.Screen) noreturn {
    //draw test
    {
        // bounce_demo(screen);

        for (screen.back_buffer) |*p| p.colors = .{
            .r = 0,
            .g = 0,
            .b = 0,
        };
        var cursor_x: usize = 0;
        var cursor_y: usize = 0;
        for (w64.CHARACTERS) |bitmap| {
            for (0..w64.CharacterBitmap.HEIGHT) |y| {
                for (0..w64.CharacterBitmap.WIDTH) |x| {
                    screen.back_buffer[(y + cursor_y) * screen.stride + x + cursor_x] = bitmap.pixels[y * w64.CharacterBitmap.WIDTH + x];
                }
            }
            cursor_x += w64.CharacterBitmap.KERNING;
            if (cursor_x >= screen.width - w64.CharacterBitmap.KERNING) {
                cursor_x = 0;
                cursor_y += w64.CharacterBitmap.HEIGHT + 1;
            }
        }
        @memcpy(screen.frame_buffer, screen.back_buffer);
    }
}
fn bounce_demo(screen: w64.Screen) noreturn {
    //TODO test with back buffer
    var cursor_y: usize = 0;
    var upwards = false;
    while (true) {
        if (upwards) {
            cursor_y -= 1;
        } else {
            cursor_y += 1;
        }
        if (cursor_y >= screen.height - w64.CharacterBitmap.HEIGHT) {
            upwards = true;
        } else if (cursor_y == 0) {
            upwards = false;
        }
        for (screen.back_buffer) |*p| p.colors = .{
            .r = 0,
            .g = 0,
            .b = 0,
        };
        draw_rect(screen, 500, cursor_y);
        {
            var cursor_x: usize = 0;
            for (w64.CHARACTERS) |bitmap| {
                for (0..w64.CharacterBitmap.HEIGHT) |y| {
                    for (0..w64.CharacterBitmap.WIDTH) |x| {
                        screen.back_buffer[(y + cursor_y) * screen.stride + (x + cursor_x)] = bitmap.pixels[y * w64.CharacterBitmap.WIDTH + x];
                    }
                }
                cursor_x += w64.CharacterBitmap.KERNING;
            }
        }
        @memcpy(screen.frame_buffer, screen.back_buffer);
        for (0..100000) |_| {
            std.atomic.spinLoopHint();
        }
    }
}

fn draw_rect(screen: w64.Screen, x: usize, y: usize) void {
    const w = 30;
    const h = 20;

    for (y..y + h) |py| {
        for (x..x + w) |px| {
            screen.back_buffer[py * screen.stride + px] = .{ .colors = .{
                .r = 0xFF,
                .g = 0xFF,
                .b = 0xFF,
            } };
        }
    }
}
fn parse_kernel_elf(arena: *toolbox.Arena) !KernelParseResult {
    var page_table_data = toolbox.RandomRemovalLinkedList(PageTableData).init(arena);
    var kernel_image_byte_stream = std.io.fixedBufferStream(KERNEL_ELF);
    var header = try std.elf.Header.read(&kernel_image_byte_stream);

    var next_free_virtual_address: usize = 0;
    var it = header.program_header_iterator(&kernel_image_byte_stream);
    var top_of_stack_address: usize = 0;
    while (it.next() catch null) |program_header| {
        switch (program_header.p_type) {
            std.elf.PT_LOAD => {
                if (program_header.p_memsz == 0) {
                    continue;
                }
                const is_executable = program_header.p_flags & std.elf.PF_X != 0;
                const is_writable = program_header.p_flags & std.elf.PF_W != 0;
                const page_table_setup_data = PageTableData{
                    .destination_virtual_address = program_header.p_vaddr,
                    .data_to_copy = KERNEL_ELF[program_header.p_offset .. program_header.p_offset + program_header.p_filesz],
                    .number_of_bytes = toolbox.align_up(program_header.p_memsz, MEMORY_PAGE_SIZE),
                    .is_executable = is_executable,
                    .is_writable = is_writable,
                };
                toolbox.assert(page_table_setup_data.data_to_copy.len <= page_table_setup_data.number_of_bytes, "number of bytes to copy should be no greater than the number of bytes to allocate", .{});
                _ = page_table_data.append(page_table_setup_data);
                next_free_virtual_address = @max(
                    next_free_virtual_address,
                    toolbox.align_down(program_header.p_vaddr + program_header.p_memsz + MEMORY_PAGE_SIZE, MEMORY_PAGE_SIZE),
                );
                println("ELF vaddr: {X}, size: {X}", .{ program_header.p_vaddr, program_header.p_memsz });
            },
            std.elf.PT_GNU_STACK => {
                const KERNEL_STACK_BOTTOM_ADDRESS = 0x1_0000_0000_0000_0000 - MEMORY_PAGE_SIZE;
                const stack_size = toolbox.align_up(program_header.p_memsz, MEMORY_PAGE_SIZE);
                top_of_stack_address = KERNEL_STACK_BOTTOM_ADDRESS - stack_size + MEMORY_PAGE_SIZE;
                const page_table_setup_data = PageTableData{
                    .destination_virtual_address = top_of_stack_address,
                    .data_to_copy = &[_]u8{},
                    .number_of_bytes = stack_size,
                    .is_executable = false,
                    .is_writable = true,
                };

                _ = page_table_data.append(page_table_setup_data);
            }, //TODO
            std.elf.PT_GNU_RELRO => {},
            std.elf.PT_PHDR => {},
            //else => toolbox.panic("Unexpected ELF section: {x}", .{program_header.p_type}),
            else => return error.UnexpectedELFSection,
        }
    }
    println("next free virtual address: {X}", .{next_free_virtual_address});
    return .{
        .next_free_virtual_address = next_free_virtual_address,
        .entry_point = header.entry,
        .top_of_stack_address = top_of_stack_address,
        .page_table_data = page_table_data,
    };
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    println(fmt, args);
    toolbox.hang();
}

//TODO:
//multicore

// const BootstrapCoreContext = struct {
//     cores_started: *usize,
//     mp: *mpsp.MPServiceProtocol,
//     print_strip: *const bool,

//     cores_detected: usize,
//     core_id: usize,
//     screen: Screen,
// };
// fn ap_entry_point(arg: ?*anyopaque) callconv(.C) void {
//     const ctx = @ptrCast(*BootstrapCoreContext, @alignCast(@alignOf(mpsp.MPServiceProtocol), arg.?));

//     _ = @atomicRmw(usize, ctx.cores_started, .Add, 1, .Monotonic);

//     while (!@atomicLoad(bool, ctx.print_strip, .SeqCst)) {
//         std.atomic.spinLoopHint();
//         serialprintln("before ", .{});
//     }
//     serialprintln("yes", .{});

//     draw_strip(ctx.core_id, ctx.cores_detected, ctx.screen);
//     toolbox.hang();
// }
// fn draw_strip(core_id: usize, cores_detected: usize, screen: Screen) void {
//     const height = screen.height / cores_detected;
//     const y0 = core_id * height;
//     serialprintln(
//         "y0: {}, height: {}, screen width: {}, screen height: {}, screen stride: {}",
//         .{ y0, height, screen.width, screen.height, screen.stride },
//     );
//     for (y0..y0 + height) |y| {
//         for (0..screen.width) |x| {
//             screen.frame_buffer[y * screen.stride + x].colors = .{
//                 .r = @intCast(u8, core_id) * 100,
//                 .g = 0,
//                 .b = 0,
//             };
//         }
//     }
// }

// var cores_detected: usize = 1;
// var core_contexts = toolbox.DynamicArray(*BootstrapCoreContext).init(&bootloader_arena, 128);
// var print_strip = false;
// {
//     var cores_started: usize = 1;
//     var core_id: usize = 1;
//     {
//         var mp: *mpsp.MPServiceProtocol = undefined;
//         var status = bs.locateProtocol(&mpsp.MPServiceProtocol.guid, null, @ptrCast(*?*anyopaque, &mp));
//         if (status != ZSUEFIStatus.Success) {
//             fatal("Cannot init multicore support! Error locating MP protocol: {}", .{status});
//         }

//         var number_of_enabled_processors: usize = 0;
//         var number_of_processors: usize = 0;
//         status = mp.mp_services_get_number_of_processors(&number_of_processors, &number_of_enabled_processors);
//         if (status != ZSUEFIStatus.Success) {
//             fatal("Cannot init multicore support! Error getting number of processors: {}", .{status});
//         }

//         var dummy_event: std.os.uefi.Event = undefined;
//         status = bs.createEvent(
//             std.os.uefi.tables.BootServices.event_notify_signal,
//             std.os.uefi.tables.BootServices.tpl_callback,
//             event_notification_callback,
//             null,
//             &dummy_event,
//         );
//         if (status != ZSUEFIStatus.Success) {
//             fatal("Failed to create dummy event to start multicore support! Error: {}", .{status});
//         }

//         //processor 0 is the BSP (main processor)
//         for (1..number_of_enabled_processors) |i| {
//             var processor_info_buffer: mpsp.ProcessorInformation = undefined;
//             status = mp.mp_services_get_processor_info(i, &processor_info_buffer);
//             if (status != ZSUEFIStatus.Success) {
//                 fatal("Failed to start multicore support! Error getting processor info: {}", .{status});
//             }

//             //ignore hyperthreads
//             if (processor_info_buffer.location.thread != 0) {
//                 continue;
//             }
//             var ctx = bootloader_arena.push(BootstrapCoreContext);
//             ctx.* = .{
//                 .mp = mp,
//                 .cores_started = &cores_started,
//                 .core_id = core_id,

//                 .screen = screen,
//                 .cores_detected = number_of_enabled_processors,
//                 .print_strip = &print_strip,
//             };
//             core_contexts.append(ctx);

//             core_id += 1;
//             cores_detected += 1;
//             status = mp.mp_services_startup_this_ap(ap_entry_point, i, dummy_event, 0, ctx, null);
//             if (status != ZSUEFIStatus.Success) {
//                 fatal("Failed to start multicore support! Error: {}", .{status});
//             }
//         }
//     }
//     while (@atomicLoad(usize, &cores_started, .Monotonic) < cores_detected) {
//         std.atomic.spinLoopHint();
//     }
//     uefiprintln("Started {} cores", .{cores_started});
// }

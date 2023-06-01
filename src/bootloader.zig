//Copyright Daniel Bokser 2023
//See LICENSE file for permissible source code usage

const std = @import("std");
const toolbox = @import("toolbox");
const mpsp = @import("mp_service_protocol.zig");

const kernel_elf = @embedFile("../zig-out/bin/kernel.elf");

const ENABLE_CONSOLE = true;

const ZSGraphicsOutputProtocol = std.os.uefi.protocols.GraphicsOutputProtocol;
const ZSGraphicsOutputModeInformation = std.os.uefi.protocols.GraphicsOutputModeInformation;
const ZSUEFIStatus = std.os.uefi.Status;
const ZSMemoryDescriptor = std.os.uefi.tables.MemoryDescriptor;

const SmallUEFIMemoryDescriptor = ZSMemoryDescriptor;

const TARGET_RESOLUTION = .{
    .width = 1280,
    .height = 720,
};
const Pixel = packed union {
    colors: packed struct(u32) {
        b: u8,
        g: u8,
        r: u8,
        reserved: u8 = 0,
    },
    data: u32,
};
comptime {
    toolbox.assert(
        @sizeOf(Pixel) == 4,
        "Pixel size incorrect. Expected: 4, Actual: {}",
        .{@sizeOf(Pixel)},
    );
}
const Screen = struct {
    pixels: []Pixel,
    width: usize,
    height: usize,
    stride: usize,
};

pub const LargeUEFIMemoryDescriptor = extern struct {
    type: std.os.uefi.tables.MemoryType,
    physical_start: u64,
    virtual_start: u64,
    number_of_pages: u64,
    attribute: std.os.uefi.tables.MemoryDescriptorAttribute,
    unknown: u64,
};

var bootloader_arena_buffer = [_]u8{0} ** toolbox.kb(512);
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

    var bootloader_arena = toolbox.Arena.init_with_buffer(&bootloader_arena_buffer);

    //graphics

    var gop: *ZSGraphicsOutputProtocol = undefined;
    var found_valid_resolution = false;
    const screen: Screen = b: {
        var status = bs.locateProtocol(&ZSGraphicsOutputProtocol.guid, null, @ptrCast(*?*anyopaque, &gop));
        if (status != ZSUEFIStatus.Success) {
            fatal("Cannot init graphics system! Error locating GOP protocol: {}", .{status});
        }

        var mode: u32 = 0;
        for (0..gop.mode.max_mode + 1) |i| {
            mode = @intCast(u32, i);
            var gop_mode_info: *ZSGraphicsOutputModeInformation = undefined;
            var size_of_info: usize = 0;
            const query_mode_status = gop.queryMode(mode, &size_of_info, &gop_mode_info);
            if ((query_mode_status == ZSUEFIStatus.Success or
                query_mode_status == ZSUEFIStatus.NotStarted) and
                (gop_mode_info.horizontal_resolution == TARGET_RESOLUTION.width and
                gop_mode_info.vertical_resolution == TARGET_RESOLUTION.height))
            {
                found_valid_resolution = true;
                status = gop.setMode(mode);
                if (status != ZSUEFIStatus.Success) {
                    fatal("Cannot init graphics system! Error setting mode {}: {}", .{ mode, status });
                }
                break;
            }
        }
        if (!found_valid_resolution) {
            fatal(
                "Failed to set screen to required resolution: {}x{}",
                .{
                    TARGET_RESOLUTION.width,
                    TARGET_RESOLUTION.height,
                },
            );
        }

        const pixels = @intToPtr([*]Pixel, gop.mode.frame_buffer_base)[0 .. gop.mode.frame_buffer_size / @sizeOf(Pixel)];
        break :b .{
            .pixels = pixels,
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
    //reset console before getting memory map and exiting, since we cannot call any services
    //after getting the memory map
    {
        _ = con_out.reset(false);
        _ = con_out.clearScreen();
        _ = con_out.setCursorPosition(0, 0);
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

    //TODO debug logging
    // for (memory_map) |desc| {
    //     serialprintln("addr: {X}, num pages: {}, type: {}", .{
    //         desc.physical_start,
    //         desc.number_of_pages,
    //         desc.type,
    //     });
    // }
    // serialprintln("rsdp: {X}", .{rsdp});
    // serialprintln("kernel size: {}", .{kernel_elf.len});
    for (screen.pixels) |*p| p.colors = .{
        .r = 0,
        .g = 0,
        .b = 0x40,
    };

    toolbox.hang();
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    uefiprintln(fmt, args);
    toolbox.hang();
}

//should only be called by BSP (main processor) and before getMemoryMap
fn uefiprintln(comptime fmt: []const u8, args: anytype) void {
    if (comptime !ENABLE_CONSOLE) {
        return;
    }
    const MAX_CHARS = 256;
    var buf8: [MAX_CHARS:0]u8 = undefined;
    var buf16: [MAX_CHARS:0]u16 = [_:0]u16{0} ** MAX_CHARS;
    const utf8 = std.fmt.bufPrintZ(&buf8, fmt ++ "\r\n", args) catch buf8[0..];
    _ = std.unicode.utf8ToUtf16Le(&buf16, utf8) catch return;
    _ = std.os.uefi.system_table.con_out.?.outputString(&buf16);
}

fn serialprintln(comptime fmt: []const u8, args: anytype) void {
    if (comptime !ENABLE_CONSOLE) {
        return;
    }
    const MAX_CHARS = 256;
    const COM1_PORT_ADDRESS = 0x3F8;
    var buf: [MAX_CHARS]u8 = undefined;
    const utf8 = std.fmt.bufPrint(&buf, fmt ++ "\r\n", args) catch buf[0..];
    for (utf8) |b| {
        asm volatile (
            \\outb %%al, %%dx
            :
            : [data] "{al}" (b),
              [port] "{dx}" (COM1_PORT_ADDRESS),
            : "rax", "rdx"
        );
    }
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
//             screen.pixels[y * screen.stride + x].colors = .{
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

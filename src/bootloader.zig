//Copyright Daniel Bokser 2023
//See LICENSE file for permissible source code usage

const std = @import("std");
const toolbox = @import("toolbox");
const mpsp = @import("mp_service_protocol.zig");

const ENABLE_CONSOLE = true;

const ZSGraphicsOutputProtocol = std.os.uefi.protocols.GraphicsOutputProtocol;
const ZSGraphicsOutputModeInformation = std.os.uefi.protocols.GraphicsOutputModeInformation;
const ZSUEFIStatus = std.os.uefi.Status;

const TARGET_RESOLUTION = .{ .w = 1280, .h = 720 };
const Pixel = packed union {
    colors: packed struct(u32) {
        b: u8,
        g: u8,
        r: u8,
        reserved: u8,
    },
    data: u32,
};

const BootstrapCoreContext = struct {
    cores_started: *usize,
    mp: *mpsp.MPServiceProtocol,

    core_id: usize,
};

var bootloader_arena_buffer = [_]u8{0} ** toolbox.mb(4);

pub fn main() noreturn {
    const system_table = std.os.uefi.system_table;
    const handle = std.os.uefi.handle;
    _ = handle;

    const con_out = system_table.con_out.?;
    _ = con_out.reset(false);
    _ = con_out.setCursorPosition(0, 0);

    const bs = system_table.boot_services.?;

    var bootloader_arena = toolbox.Arena.init_with_buffer(&bootloader_arena_buffer);

    //graphics

    var gop: *ZSGraphicsOutputProtocol = undefined;
    var found_valid_resolution = false;
    {
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
                (gop_mode_info.horizontal_resolution == TARGET_RESOLUTION.w and
                gop_mode_info.vertical_resolution == TARGET_RESOLUTION.h))
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
        fatal("Failed to set screen to required resolution: {}x{}", .{ TARGET_RESOLUTION.w, TARGET_RESOLUTION.h });
    }

    const frame_buffer = @intToPtr([*]Pixel, gop.mode.frame_buffer_base)[0 .. gop.mode.frame_buffer_size / @sizeOf(Pixel)];
    _ = frame_buffer;

    var cores_started: usize = 1;
    var cores_detected: usize = 1;
    {
        var mp: *mpsp.MPServiceProtocol = undefined;
        var status = bs.locateProtocol(&mpsp.MPServiceProtocol.guid, null, @ptrCast(*?*anyopaque, &mp));
        if (status != ZSUEFIStatus.Success) {
            fatal("Cannot init multicore support! Error locating MP protocol: {}", .{status});
        }

        var number_of_enabled_processors: usize = 0;
        var number_of_processors: usize = 0;
        status = mp.mp_services_get_number_of_processors(&number_of_processors, &number_of_enabled_processors);
        if (status != ZSUEFIStatus.Success) {
            fatal("Cannot init multicore support! Error getting number of processors: {}", .{status});
        }

        var dummy_event: std.os.uefi.Event = undefined;
        status = bs.createEvent(
            std.os.uefi.tables.BootServices.event_notify_signal,
            std.os.uefi.tables.BootServices.tpl_callback,
            event_notification_callback,
            null,
            &dummy_event,
        );
        if (status != ZSUEFIStatus.Success) {
            fatal("Failed to create dummy event to start multicore support! Error: {}", .{status});
        }

        //processor 0 is the BSP (main processor)
        for (1..number_of_enabled_processors) |i| {
            var processor_info_buffer: mpsp.ProcessorInformation = undefined;
            status = mp.mp_services_get_processor_info(i, &processor_info_buffer);
            if (status != ZSUEFIStatus.Success) {
                fatal("Failed to start multicore support! Error getting processor info: {}", .{status});
            }

            //ignore hyperthreads
            if (processor_info_buffer.location.thread != 0) {
                continue;
            }
            var ctx = bootloader_arena.push(BootstrapCoreContext);
            ctx.* = .{
                .mp = mp,
                .cores_started = &cores_started,
                .core_id = cores_detected,
            };

            cores_detected += 1;
            status = mp.mp_services_startup_this_ap(ap_entry_point, i, dummy_event, 0, ctx, null);
            if (status != ZSUEFIStatus.Success) {
                fatal("Failed to start multicore support! Error: {}", .{status});
            }
        }
    }
    while (@atomicLoad(usize, &cores_started, .Monotonic) < cores_detected) {
        asm volatile ("pause");
    }

    uefiprintln("Started {} cores", .{cores_started});
    hang();
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    uefiprintln(fmt, args);
    hang();
}

fn hang() noreturn {
    while (true) {
        asm volatile ("pause");
    }
}

//should only be called by BSP (main processor)
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

fn ap_entry_point(arg: ?*anyopaque) callconv(.C) void {
    const ctx = @ptrCast(*BootstrapCoreContext, @alignCast(@alignOf(mpsp.MPServiceProtocol), arg.?));
    //TODO: remove
    // var processor_number: usize = 0;
    // var status = ctx.mp.mp_services_whoami(&processor_number);
    // if (status != ZSUEFIStatus.Success) {
    //     //fail
    //     hang();
    // }

    _ = @atomicRmw(usize, ctx.cores_started, .Add, 1, .Monotonic);

    hang();
}

fn event_notification_callback(event: std.os.uefi.Event, ctx: ?*anyopaque) callconv(.C) void {
    _ = ctx;
    _ = event;
}

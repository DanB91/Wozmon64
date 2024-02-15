const toolbox = @import("toolbox");
const std = @import("std");
const w64 = @import("wozmon64_kernel.zig");
const kernel_memory = @import("kernel_memory.zig");

const ErrorLog = struct {
    error_log: toolbox.RandomRemovalLinkedList(ErrorLogEntry) = .{},
    arena: ?*toolbox.Arena = null,
};

const ErrorLogEntry = struct {
    message: toolbox.String8 = .{},
    stacktrace: toolbox.DynamicArray(u64) = .{},
};

threadlocal var g_state: ErrorLog = .{};

pub fn log_error(comptime fmt: []const u8, args: anytype) void {
    if (g_state.arena == null) {
        g_state.arena = toolbox.Arena.init(w64.MEMORY_PAGE_SIZE);
        g_state.error_log = toolbox.RandomRemovalLinkedList(ErrorLogEntry).init(g_state.arena.?);
    }
    const arena = g_state.arena;
    const message = toolbox.str8fmt(fmt, args, arena.?);
    var stacktrace = toolbox.DynamicArray(u64).init(g_state.arena.?, 16);

    var it = w64.StackUnwinder.init();
    while (it.next()) |address| {
        stacktrace.append(address);
    }
    _ = g_state.error_log.append(.{
        .message = message,
        .stacktrace = stacktrace,
    });
}

pub fn get_log() toolbox.RandomRemovalLinkedList(ErrorLogEntry) {
    return g_state.error_log;
}

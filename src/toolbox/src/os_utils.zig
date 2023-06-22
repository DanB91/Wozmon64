const std = @import("std");

pub fn hang() noreturn {
    while (true) {
        std.atomic.spinLoopHint();
    }
}

pub fn busy_wait(count: usize) void {
    for (0..count) |_| {
        std.atomic.spinLoopHint();
    }
}

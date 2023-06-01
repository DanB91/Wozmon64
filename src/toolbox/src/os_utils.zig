const std = @import("std");

pub fn hang() noreturn {
    while (true) {
        std.atomic.spinLoopHint();
    }
}
